extends Node

# OpenXR mesh 路径的 360° 环境背景控制器。
#
# 同时支持：
# - 视频：Godot 内置 Ogg Theora (.ogv) 循环播放；
# - 图片：等距柱状 2:1 全景图片，静态显示；
# - 关闭：恢复 WorldEnvironment 原始背景。
#
# 视频仍然放在 16x16 SubViewport 中，get_video_texture() 直接交给 Sky Shader
# 采样，避免创建 8K RenderTarget。图片则直接上传为 ImageTexture，显存占用
# 远低于 8K 视频解码，也不会占用 CPU 视频解码线程。

const ENVIRONMENT_SKY_SHADER := preload("res://shaders/environment_sky.gdshader")

const DEFAULT_VIDEO_CANDIDATES := [
	"res://environment/environment_8k.ogv",
	"res://environment/environment.ogv",
	"res://environment/loop.ogv",
	"user://environment_8k.ogv",
]

const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const IMAGE_DIRECTORIES := [
	"res://environment/images",
	"res://environment",
	"user://environment_images",
	"user://environment",
]
const MAX_IMAGE_CHOICES := 32

enum BackgroundKind {
	OFF,
	VIDEO,
	IMAGE,
}

var world_environment: WorldEnvironment
var video_viewport: SubViewport
var video_player: VideoStreamPlayer
var sky: Sky
var sky_material: ShaderMaterial
var placeholder_texture: ImageTexture
var image_texture: Texture2D

var background_choices: Array[Dictionary] = []
var current_choice_index := 0
var current_mode := BackgroundKind.OFF
var current_path := ""

var video_texture_ready := false
var last_video_texture: Texture2D
var wait_frames := 0

var cli_override := false
var requested_video_path := ""
var requested_image_path := ""
var background_rotation_degrees := 0.0
var rotation_cli_override := false
var no_environment_video := false

var original_background_mode := Environment.BG_COLOR
var original_background_color := Color(0.0, 0.0, 0.0, 0.0)
var original_sky: Sky = null
var original_transparent_bg := false
var environment_saved := false


func setup(target_world_environment: WorldEnvironment) -> bool:
	world_environment = target_world_environment
	if world_environment == null or world_environment.environment == null:
		push_warning("[ENV] WorldEnvironment/environment is unavailable")
		return false

	_save_original_environment()
	requested_video_path = _get_requested_video_path()
	requested_image_path = _get_requested_image_path()
	no_environment_video = _has_arg("--no-environment-video")
	cli_override = _detect_cli_override()

	_create_sky_resources()
	refresh_background_choices()

	# 显式指定图片时图片优先；其次是显式视频；最后才是默认视频。
	# 即使没有任何媒体也返回 true，这样 OpenXR 设置面板仍可在运行时选择
	# 后来放入目录的图片。
	if not requested_image_path.is_empty():
		if not _select_by_path(BackgroundKind.IMAGE, requested_image_path):
			push_warning("[ENV] 指定的环境图片不存在或无法读取: %s" % requested_image_path)
			use_default_background()
	elif not requested_video_path.is_empty():
		if not _select_by_path(BackgroundKind.VIDEO, requested_video_path):
			push_warning("[ENV] 指定的环境视频不存在或无法读取: %s" % requested_video_path)
			use_default_background()
	elif no_environment_video:
		select_background_choice(0)
	else:
		use_default_background()

	print("[ENV] 背景选择列表: %d 项，当前=%s" % [background_choices.size(), get_background_label()])
	set_process(true)
	return true


func _save_original_environment() -> void:
	if environment_saved:
		return
	var env := world_environment.environment
	original_background_mode = env.background_mode
	original_background_color = env.background_color
	original_sky = env.sky
	original_transparent_bg = get_viewport().transparent_bg
	environment_saved = true


func _create_sky_resources() -> void:
	sky_material = ShaderMaterial.new()
	sky_material.shader = ENVIRONMENT_SKY_SHADER

	# Shader sampler 在图片或视频纹理出现前必须有有效纹理，否则可能产生
	# 着色器警告。2x1 黑色占位纹理会一直保留到第一次激活媒体。
	var placeholder_image := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	placeholder_image.fill(Color.BLACK)
	placeholder_texture = ImageTexture.create_from_image(placeholder_image)
	sky_material.set_shader_parameter("environment_tex", placeholder_texture)
	_apply_shader_options()

	sky = Sky.new()
	sky.sky_material = sky_material

	# 视频播放器必须始终有有效纹理；16x16 SubViewport 只负责让视频解码器
	# 提供纹理，不把 8K 内容重新渲染到一张大 RenderTarget。
	video_viewport = SubViewport.new()
	video_viewport.name = "EnvironmentVideoViewport"
	video_viewport.size = Vector2i(16, 16)
	video_viewport.disable_3d = true
	video_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(video_viewport)

	video_player = VideoStreamPlayer.new()
	video_player.name = "EnvironmentVideoPlayer"
	video_player.loop = true
	video_player.autoplay = false
	video_player.expand = true
	video_player.volume_db = -80.0
	video_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	video_viewport.add_child(video_player)
	video_player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func refresh_background_choices(preferred_image_path: String = "") -> void:
	var choices: Array[Dictionary] = []
	var seen_video := {}
	var seen_images := {}

	choices.append({
		"mode": BackgroundKind.OFF,
		"path": "",
		"label": "关闭",
	})

	# 默认视频仅在未使用 --no-environment-video 时加入。显式指定的视频
	# 路径即使带 no 标志也保留，方便诊断和覆盖默认值。
	if not no_environment_video:
		for candidate in DEFAULT_VIDEO_CANDIDATES:
			_append_video_choice(choices, seen_video, candidate)
	if not requested_video_path.is_empty():
		_append_video_choice(choices, seen_video, requested_video_path)

	var effective_preferred_image := preferred_image_path
	if effective_preferred_image.is_empty() and current_mode == BackgroundKind.IMAGE:
		effective_preferred_image = current_path
	if effective_preferred_image.is_empty():
		effective_preferred_image = requested_image_path
	var image_paths := _collect_image_paths(effective_preferred_image)
	for image_path in image_paths:
		_append_image_choice(choices, seen_images, image_path)

	# 当前已经激活但不在扫描结果中的路径也要保留，避免刷新后选择丢失。
	if current_mode == BackgroundKind.VIDEO and not current_path.is_empty():
		_append_video_choice(choices, seen_video, current_path)
	elif current_mode == BackgroundKind.IMAGE and not current_path.is_empty():
		_append_image_choice(choices, seen_images, current_path)

	background_choices = choices
	current_choice_index = _find_choice_index(current_mode, current_path)
	if current_choice_index < 0:
		current_choice_index = 0


func _append_video_choice(choices: Array[Dictionary], seen: Dictionary, raw_path: String) -> void:
	var path := _normalize_media_path(raw_path)
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var key := _path_key(path)
	if seen.has(key):
		return
	seen[key] = true
	choices.append({
		"mode": BackgroundKind.VIDEO,
		"path": path,
		"label": "视频",
	})


func _append_image_choice(choices: Array[Dictionary], seen: Dictionary, raw_path: String) -> void:
	var path := _normalize_media_path(raw_path)
	if path.is_empty() or not FileAccess.file_exists(path) or not _is_image_path(path):
		return
	var key := _path_key(path)
	if seen.has(key):
		return
	seen[key] = true
	choices.append({
		"mode": BackgroundKind.IMAGE,
		"path": path,
		"label": "图片: %s" % _display_name(path),
	})


func _collect_image_paths(preferred_path: String) -> Array[String]:
	var result: Array[String] = []
	var seen := {}
	var preferred_normalized := _normalize_media_path(preferred_path)
	var directories: Array[String] = []
	for directory in IMAGE_DIRECTORIES:
		directories.append(directory)

	# 显式指定或当前使用的图片先加入，避免排序后被 32 张上限截掉。
	_append_existing_image(result, seen, preferred_normalized)
	for directory in directories:
		var dir := DirAccess.open(directory)
		if dir == null:
			continue
		for file_name in dir.get_files():
			_append_existing_image(result, seen, directory.path_join(file_name))

	result.sort()
	# 保持目录中的自然排序，不把当前图片强行挪到列表首位。
	# 这样从当前图片向右切换时，会进入它的下一张，而不是跳回列表开头。
	if result.size() > MAX_IMAGE_CHOICES:
		var preferred_index := result.find(preferred_normalized)
		if not preferred_normalized.is_empty() and preferred_index >= MAX_IMAGE_CHOICES:
			var limited: Array[String] = []
			for index in range(MAX_IMAGE_CHOICES - 1):
				limited.append(result[index])
			limited.append(preferred_normalized)
			limited.sort()
			result = limited
		else:
			result.resize(MAX_IMAGE_CHOICES)
	return result


func _append_existing_image(result: Array[String], seen: Dictionary, raw_path: String) -> void:
	var path := _normalize_media_path(raw_path)
	if path.is_empty() or not FileAccess.file_exists(path) or not _is_image_path(path):
		return
	var key := _path_key(path)
	if seen.has(key):
		return
	seen[key] = true
	result.append(path)


func _is_image_path(path: String) -> bool:
	return path.get_extension().to_lower() in IMAGE_EXTENSIONS


func _select_by_path(mode: int, raw_path: String) -> bool:
	var path := _normalize_media_path(raw_path)
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	refresh_background_choices()
	var index := _find_choice_index(mode, path)
	if index < 0:
		return false
	return select_background_choice(index)


func select_background_choice(index: int) -> bool:
	if background_choices.is_empty():
		return false
	var safe_index := posmod(index, background_choices.size())
	var choice: Dictionary = background_choices[safe_index]
	var mode := int(choice.get("mode", BackgroundKind.OFF))
	var path := String(choice.get("path", ""))

	if mode == BackgroundKind.VIDEO:
		if not _activate_video(path):
			return false
	elif mode == BackgroundKind.IMAGE:
		if not _activate_image(path):
			return false
	else:
		_deactivate()

	current_choice_index = safe_index
	current_mode = mode if mode in [BackgroundKind.VIDEO, BackgroundKind.IMAGE] else BackgroundKind.OFF
	current_path = path if current_mode != BackgroundKind.OFF else ""
	return true


func cycle_background_choice(direction: int) -> void:
	if direction == 0:
		return
	if background_choices.is_empty():
		refresh_background_choices()
	if background_choices.is_empty():
		return
	var step := 1 if direction > 0 else -1
	select_background_choice(posmod(current_choice_index + step, background_choices.size()))


func use_default_background() -> void:
	refresh_background_choices()
	for index in range(background_choices.size()):
		var choice: Dictionary = background_choices[index]
		if int(choice.get("mode", BackgroundKind.OFF)) == BackgroundKind.VIDEO:
			select_background_choice(index)
			return
	# 图片是用户显式选择项，不在没有视频时自动启用，避免扫描目录里的
	# 任意图片悄悄改变默认背景。
	select_background_choice(0)


func apply_saved_choice(mode_name: String, image_path: String) -> void:
	if cli_override:
		print("[ENV] 命令行/环境变量已指定背景，忽略已保存的环境背景选择")
		return
	var normalized_mode := mode_name.strip_edges().to_lower()
	refresh_background_choices(image_path if normalized_mode == "image" else "")
	if normalized_mode == "off":
		select_background_choice(0)
		return
	if normalized_mode == "image":
		var index := _find_choice_index(BackgroundKind.IMAGE, _normalize_media_path(image_path))
		if index >= 0:
			select_background_choice(index)
		else:
			use_default_background()
		return
	if normalized_mode == "video":
		for choice_index in range(background_choices.size()):
			var choice: Dictionary = background_choices[choice_index]
			if int(choice.get("mode", BackgroundKind.OFF)) == BackgroundKind.VIDEO:
				select_background_choice(choice_index)
				return
		use_default_background()
		return
	use_default_background()


func _activate_video(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	if video_player == null or video_viewport == null:
		return false

	var stream := VideoStreamTheora.new()
	stream.set_file(path)
	video_player.stream = stream
	video_player.loop = true
	video_player.play()
	video_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	image_texture = null
	video_texture_ready = false
	last_video_texture = null
	wait_frames = 0
	sky_material.set_shader_parameter("environment_tex", placeholder_texture)
	_activate_sky()

	var file_size_mb := 0.0
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		file_size_mb = float(file.get_length()) / (1024.0 * 1024.0)
		file.close()
	print("[ENV] 环境视频已启用: %s (%.1f MB, loop=%s)" % [path, file_size_mb, str(video_player.loop)])
	return true


func _activate_image(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false

	# 项目内置图片优先走 Godot 导入资源，避免 load_from_file 在导出包中的
	# 兼容性警告；用户从外部目录选择的图片再直接解码为 ImageTexture。
	var texture: Texture2D = null
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var resource := ResourceLoader.load(path)
		if resource is Texture2D:
			texture = resource

	if texture == null:
		var image := Image.load_from_file(path)
		if image == null or image.is_empty():
			push_warning("[ENV] 图片解码失败: %s" % path)
			return false
		# 统一转成 RGBA8，避免不同来源图片的压缩格式/通道顺序影响天空采样。
		image.convert(Image.FORMAT_RGBA8)
		texture = ImageTexture.create_from_image(image)

	if texture == null:
		push_warning("[ENV] 图片纹理创建失败: %s" % path)
		return false
	image_texture = texture

	if video_player != null:
		video_player.stop()
	if video_viewport != null:
		video_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	last_video_texture = null
	video_texture_ready = false
	sky_material.set_shader_parameter("environment_tex", image_texture)
	_activate_sky()
	print("[ENV] 环境图片已启用: %s (%dx%d)" % [path, texture.get_width(), texture.get_height()])
	return true


func _activate_sky() -> void:
	if world_environment == null or world_environment.environment == null:
		return
	world_environment.environment.sky = sky
	world_environment.environment.background_mode = Environment.BG_SKY
	world_environment.environment.background_energy_multiplier = 1.0
	# mesh 路径没有 composition layer，天空必须真正写入投影层。
	get_viewport().transparent_bg = false


func _deactivate() -> void:
	if video_player != null:
		video_player.stop()
	if video_viewport != null:
		video_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	last_video_texture = null
	video_texture_ready = false
	image_texture = null
	if environment_saved and world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		env.sky = original_sky
		env.background_mode = original_background_mode
		env.background_color = original_background_color
	get_viewport().transparent_bg = original_transparent_bg
	print("[ENV] 环境背景已关闭")


func _process(_delta: float) -> void:
	if current_mode != BackgroundKind.VIDEO:
		return
	if video_player == null or sky_material == null:
		return

	wait_frames += 1
	var texture := video_player.get_video_texture()
	if texture == null:
		if wait_frames % 120 == 0:
			print("[ENV] 等待视频纹理... playing=%s pos=%.2f" % [str(video_player.is_playing()), video_player.get_stream_position()])
		return

	if texture != last_video_texture:
		last_video_texture = texture
		sky_material.set_shader_parameter("environment_tex", texture)
		if not video_texture_ready:
			video_texture_ready = true
			print("[ENV] 视频纹理就绪: %s，开始作为 360° 天空播放" % str(texture.get_size()))
		else:
			print("[ENV] 视频纹理引用已更新: %s" % str(texture.get_size()))


func _apply_shader_options() -> void:
	if sky_material == null:
		return
	var rotation_arg := _arg_value("--environment-rotation", "")
	if not rotation_arg.is_empty():
		background_rotation_degrees = wrapf(float(rotation_arg), -180.0, 180.0)
		rotation_cli_override = true
	var exposure := float(_arg_value("--environment-exposure", "1.0"))
	var flip_y := _arg_bool("--environment-flip-y", false)
	sky_material.set_shader_parameter("rotation_radians", deg_to_rad(background_rotation_degrees))
	sky_material.set_shader_parameter("exposure", clampf(exposure, 0.0, 4.0))
	sky_material.set_shader_parameter("flip_y", flip_y)


func get_background_label() -> String:
	if current_mode == BackgroundKind.VIDEO:
		return "视频"
	if current_mode == BackgroundKind.IMAGE:
		return "图片: %s" % _display_name(current_path)
	return "关闭"


func get_background_description() -> String:
	if current_mode == BackgroundKind.VIDEO:
		return "当前播放 360° 等距柱状环境视频；视频方案保留，可用左右键切换到图片或关闭。"
	if current_mode == BackgroundKind.IMAGE:
		return "当前显示本地全景图片：%s；图片和视频互斥，可用左右键切换。" % _display_name(current_path)
	return "关闭环境背景；左右键可切换到视频或本地图片。"


func get_mode_name() -> String:
	if current_mode == BackgroundKind.VIDEO:
		return "video"
	if current_mode == BackgroundKind.IMAGE:
		return "image"
	return "off"


func get_current_path() -> String:
	return current_path


func set_background_rotation_degrees(value: float) -> void:
	background_rotation_degrees = wrapf(value, -180.0, 180.0)
	if sky_material != null:
		sky_material.set_shader_parameter("rotation_radians", deg_to_rad(background_rotation_degrees))


func get_background_rotation_degrees() -> float:
	return background_rotation_degrees


func has_cli_rotation_override() -> bool:
	return rotation_cli_override


func has_cli_override() -> bool:
	return cli_override


func _find_choice_index(mode: int, raw_path: String) -> int:
	var normalized_path := _normalize_media_path(raw_path)
	for index in range(background_choices.size()):
		var choice: Dictionary = background_choices[index]
		var choice_mode := int(choice.get("mode", BackgroundKind.OFF))
		var choice_path := String(choice.get("path", ""))
		if mode == BackgroundKind.OFF and choice_mode == BackgroundKind.OFF:
			return index
		if mode == choice_mode and not normalized_path.is_empty() and _path_key(choice_path) == _path_key(normalized_path):
			return index
	return -1


func _get_requested_video_path() -> String:
	var raw := _arg_value("--environment-video", "")
	if raw.strip_edges().is_empty():
		raw = OS.get_environment("VR3D_ENVIRONMENT_VIDEO")
	return _normalize_media_path(raw)


func _get_requested_image_path() -> String:
	var raw := _arg_value("--environment-image", "")
	if raw.strip_edges().is_empty():
		raw = OS.get_environment("VR3D_ENVIRONMENT_IMAGE")
	return _normalize_media_path(raw)


func _detect_cli_override() -> bool:
	if not requested_video_path.is_empty() or not requested_image_path.is_empty():
		return true
	return no_environment_video


func _normalize_media_path(path: String) -> String:
	var normalized := path.strip_edges().replace("\\", "/")
	if normalized.is_empty():
		return ""
	if normalized.begins_with("res://") or normalized.begins_with("user://") or normalized.is_absolute_path():
		return normalized
	# Windows 盘符路径经过斜杠替换后有时不被 is_absolute_path 识别。
	if normalized.length() >= 2 and normalized.substr(1, 1) == ":":
		return normalized
	# 普通相对路径按 Godot 项目根目录解释，方便写 environment/xxx.ogv。
	return "res://" + normalized


func _display_name(path: String) -> String:
	var base_name := path.get_file().get_basename()
	if base_name.is_empty():
		base_name = path.get_file()
	if base_name.length() > 10:
		return base_name.substr(0, 9) + "…"
	return base_name


func _path_key(path: String) -> String:
	return path.replace("\\", "/").to_lower()


func _has_arg(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args()


func _arg_value(prefix: String, default_value: String) -> String:
	var key := prefix + "="
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key):
			return arg.substr(key.length())
	return default_value


func _arg_bool(prefix: String, default_value: bool) -> bool:
	var raw := _arg_value(prefix, "1" if default_value else "0").to_lower()
	return raw in ["1", "true", "yes", "on"]