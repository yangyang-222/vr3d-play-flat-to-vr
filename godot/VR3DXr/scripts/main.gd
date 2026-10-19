extends Node3D

# VR3D OpenXR 主脚本（moonlightXR 复刻版）
# Python: 桌面捕获 + MiDaS 深度 → [彩色图 + 深度图] 字节直传
# Godot: shader 里用深度做 DIBR（左右眼视差）→ OpenXR → VD → Pico

const XR_SETTINGS_PANEL := preload("res://scripts/xr_settings_panel.gd")
const XR_COMPOSITION_VIDEO := preload("res://scripts/xr_composition_video.gd")
const XR_ENVIRONMENT_VIDEO := preload("res://scripts/xr_environment_video.gd")

const DEFAULT_PORT := 48372
var server_port := DEFAULT_PORT
const FALLBACK_W := 2560
const FALLBACK_H := 1440
const FALLBACK_D := 96
const STREAM_MAGIC := "V3D1"
const STREAM_CONFIG_VERSION := 1
const STREAM_CONFIG_SIZE := 20
const EDGE_FADE_MAX_DEPTH_DELTA := 0.6
var color_w := FALLBACK_W
var color_h := FALLBACK_H
var depth_n := FALLBACK_D
var y_size := color_w * color_h
var uv_size := (color_w / 2) * (color_h / 2)
var depth_payload_size := depth_n * depth_n * 4
var payload_size := y_size + uv_size * 2 + depth_payload_size
var frame_ack := PackedByteArray([6])

var rx_thread: Thread
var rx_mutex := Mutex.new()
var rx_stop := false
var pending_ready := false
var pending_y := PackedByteArray()
var pending_u := PackedByteArray()
var pending_v := PackedByteArray()
var pending_depth := PackedByteArray()
var pending_has_color := false
var pending_has_depth := false
var pending_stream_config := false
var pending_color_w := FALLBACK_W
var pending_color_h := FALLBACK_H
var pending_depth_n := FALLBACK_D
var received_frames := 0
var replaced_frames := 0

var sbs_tex: ImageTexture      # 调试用（--tex2d/--localpng）
var color_tex: ImageTexture    # 主模式：Y 平面
var u_tex: ImageTexture        # 主模式：U 平面
var v_tex: ImageTexture        # 主模式：V 平面
var depth_tex: ImageTexture    # 主模式：深度图
var plane_y_image: Image
var plane_u_image: Image
var plane_v_image: Image
var plane_depth_image: Image
var last_plane_y := PackedByteArray()
var last_plane_u := PackedByteArray()
var last_plane_v := PackedByteArray()
var last_plane_depth := PackedByteArray()
var depth_update_count := 0
var mat: ShaderMaterial
var tex_rect: TextureRect

var n_frames := 0
var t_last := 0
var solid_mode := false
var shot_t := 0
var last_frame_save := 0
var capture_debug := false
var rx_probe := false
var render_scale_override := -1.0
var last_apply_ms := 0.0
var perf_last_ms := 0
var xr_settings_panel: Node3D
var xr_active := false
var composition_video: Node3D = null
var xr_environment_video: Node = null
var no_texture := false
var dump_eyes := false
var eye_routing_test := false

func _configure_server_port() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server-port="):
			var requested := int(arg.trim_prefix("--server-port="))
			if requested >= 1 and requested <= 65535:
				server_port = requested
			else:
				push_warning("[VR3D] ignored invalid --server-port=%s" % requested)

func _configure_render_scale() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--render-scale="):
			var requested := float(arg.trim_prefix("--render-scale="))
			if requested >= 0.25 and requested <= 2.0:
				render_scale_override = requested
			else:
				push_warning("[VR3D] ignored invalid --render-scale=%s" % arg)

func _configure_xr_transparent_background() -> void:
	# The video is an OpenXR composition layer below the projection layer. Keep
	# the projection layer transparent so controllers, lasers, and UI can sit on
	# top without the old 3D quad covering the composition video.
	get_viewport().transparent_bg = true
	var world_env := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env != null and world_env.environment != null:
		world_env.environment.background_mode = Environment.BG_COLOR
		world_env.environment.background_color = Color(0.0, 0.0, 0.0, 0.0)

func _apply_render_scale(xr, default_multiplier: float = 1.0) -> void:
	# 视频走 OpenXR composition layer 时，投影层只剩透明背景、手柄、激光和 UI。
	# 降低投影层倍率不会降低视频层分辨率，却能显著减少 XR 主视口开销。
	# 默认 composition=0.5、mesh=1.0，仍可用 --render-scale= 覆盖。
	var multiplier := render_scale_override if render_scale_override > 0.0 else default_multiplier
	if xr.has_method("set_render_target_size_multiplier"):
		xr.call("set_render_target_size_multiplier", multiplier)
	if xr.has_method("get_render_target_size_multiplier"):
		var actual: float = xr.call("get_render_target_size_multiplier")
		print("[VR3D] OpenXR 渲染倍率=%.2f（请求 %.2f）视口=%s" % [actual, multiplier, str(get_viewport().get_visible_rect().size)])

func _ready() -> void:
	_configure_server_port()
	_configure_render_scale()
	var xr := XRServer.get_primary_interface()
	if xr and xr.is_initialized():
		print("[VR3D] XR 会话活动: ", xr.get_name())
		get_viewport().use_xr = true
		xr_active = true
		if xr.has_method("get_display_refresh_rate"):
			print("[VR3D] OpenXR display refresh=%.1f Hz" % float(xr.call("get_display_refresh_rate")))
		if xr.has_method("get_available_display_refresh_rates"):
			print("[VR3D] OpenXR available refresh rates=", xr.call("get_available_display_refresh_rates"))
		_configure_xr_transparent_background()
	else:
		print("[VR3D] 窗口模式（无 XR 会话，用普通 Camera3D）")
		var xrcam := get_node("XROrigin3D/XRCamera3D") as XRCamera3D
		if xrcam:
			xrcam.visible = false
		var cam3 := Camera3D.new()
		cam3.name = "WindowCam"
		cam3.current = true
		cam3.position = Vector3(0, 1.7, 0)
		add_child(cam3)
		cam3.look_at(Vector3(0, 1.7, -3))

	var quad := get_node("XROrigin3D/ScreenQuad") as MeshInstance3D

	# 调试模式：--solid → 闪烁测试（验证 OpenXR 渲染管线）
	var args := OS.get_cmdline_user_args()
	capture_debug = "--capture-debug" in args
	rx_probe = "--rx-probe" in args
	no_texture = "--no-texture" in args
	dump_eyes = "--dump-eyes" in args
	eye_routing_test = "--eye-routing-test" in args
	if capture_debug:
		print("[VR3D] 已启用诊断截图；正常运行请勿使用 --capture-debug")
	if "--eyetest" in args:
		# 诊断：左右眼颜色标记（左眼红、右眼蓝），验证 OpenXR 逐眼采样
		var emat := ShaderMaterial.new()
		var esh := Shader.new()
		esh.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { float is_left = 1.0 - float(VIEW_INDEX); ALBEDO = mix(vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), is_left); }"
		emat.shader = esh
		quad.material_override = emat
		print("[VR3D] 左右眼颜色诊断（左红右蓝）")
		shot_t = 0
		return
	if "--tex2d" in args:
		# 根视口 2D TextureRect 直接显示 ImageTexture，验证纹理有效性
		var layer := CanvasLayer.new()
		add_child(layer)
		tex_rect = TextureRect.new()
		tex_rect.position = Vector2.ZERO
		tex_rect.size = Vector2(960, 540)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		layer.add_child(tex_rect)
		if "--localpng" in args:
			var li := Image.load_from_file("G:/24youxi/VR3D/godot_frame.png")
			li.convert(Image.FORMAT_RGBA8)
			sbs_tex = ImageTexture.create_from_image(li)
			tex_rect.texture = sbs_tex
			print("[VR3D] 本地 PNG 加载: ", li.get_size(), " 纹理: ", sbs_tex.get_size())
			shot_t = 0
			t_last = Time.get_ticks_msec()
			return
		if "--localjpg" in args:
			var f := FileAccess.open("G:/24youxi/VR3D/test.jpg", FileAccess.READ)
			var bytes := f.get_buffer(f.get_length())
			f.close()
			var ji := Image.new()
			var jerr := ji.load_jpg_from_buffer(bytes)
			print("[VR3D] JPEG buffer 解码 err=", jerr, " size=", ji.get_size())
			if jerr == OK:
				sbs_tex = ImageTexture.create_from_image(ji)
				tex_rect.texture = sbs_tex
				print("[VR3D] JPEG 纹理: ", sbs_tex.get_size())
			shot_t = 0
			t_last = Time.get_ticks_msec()
			return
		print("[VR3D] 2D ImageTexture 直接显示测试")
		_connect()
		t_last = Time.get_ticks_msec()
		shot_t = 0
		return
	if "--subtest" in args:
		var sub := SubViewport.new()
		sub.name = "SBSViewport"
		sub.size = Vector2i(800, 400)
		sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(sub)
		var cr := ColorRect.new()
		cr.color = Color(1, 0, 0)
		cr.size = Vector2(800, 400)
		sub.add_child(cr)
		var mat2 := (quad.material_override as ShaderMaterial).duplicate()
		quad.material_override = mat2
		mat2.set_shader_parameter("sbs_tex", sub.get_texture())
		print("[VR3D] SubViewport 纯色测试")
		shot_t = 0
		t_last = Time.get_ticks_msec()
		return
	if "--solid" in args:
		solid_mode = true
		var flash := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = "shader_type spatial; render_mode unshaded, cull_disabled; void fragment() { ALBEDO = vec3(step(fract(TIME*2.0), 0.5), 0.0, 0.0); }"
		flash.shader = sh
		quad.material_override = flash
		print("[VR3D] 闪烁模式")
		_connect()
		t_last = Time.get_ticks_msec()
		return

	mat = (quad.material_override as ShaderMaterial).duplicate()
	quad.material_override = mat
	_create_placeholder_textures()

	var xr_camera := get_node("XROrigin3D/XRCamera3D") as XRCamera3D
	var xr_origin := get_node("XROrigin3D") as XROrigin3D
	# Mesh projection is the default: VDXR does not route per-eye composition
	# layers reliably (both eyes showed the blue right-eye layer), while the native
	# mesh + VIEW_INDEX path was verified to deliver distinct left/right images.
	# The composition layer stays available behind an explicit --composition flag.
	var use_composition := xr_active and ("--composition" in args) and not ("--mesh" in args)
	if xr_active:
		_apply_render_scale(xr, 0.5 if use_composition else 1.0)
	# 360° 环境视频只走 mesh 路径。composition layer 位于投影层下方，
	# 若同时绘制天空会遮住 composition 视频，因此这里显式跳过。
	var allow_window_environment_test := not xr_active and (
		"--environment-video-test" in args
			or "--environment-image-test" in args
			or _has_cmdline_prefix("--environment-image=")
	)
	if use_composition and (_has_cmdline_prefix("--environment-video=") or _has_cmdline_prefix("--environment-image=")):
		print("[ENV] composition 路径已启用；为避免遮住 composition 视频，天空环境背景禁用")
	elif (xr_active and not use_composition) or allow_window_environment_test:
		var world_env := get_node_or_null("WorldEnvironment") as WorldEnvironment
		xr_environment_video = XR_ENVIRONMENT_VIDEO.new()
		add_child(xr_environment_video)
		if not xr_environment_video.setup(world_env):
			xr_environment_video.queue_free()
			xr_environment_video = null
	if use_composition:
		composition_video = XR_COMPOSITION_VIDEO.new()
		add_child(composition_video)
		if composition_video.setup(quad, mat, xr_origin, xr_camera):
			composition_video.apply_video_textures(color_tex, u_tex, v_tex, depth_tex)
			composition_video.set_stereo_params(0.005, 0.50, 1.0, false)
			composition_video.set_diagnostics(dump_eyes, eye_routing_test)
			composition_video.sync_screen_transform()
		else:
			composition_video.queue_free()
			composition_video = null
			quad.material_override = mat
			print("[COMP] composition unavailable; using mesh path")
	else:
		print("[VR3D] render path: mesh projection (default; --composition switches back)")
	if "--no-ui" in args:
		print("[VR3D] settings UI disabled for diagnostic")
	else:
		xr_settings_panel = XR_SETTINGS_PANEL.new()
		add_child(xr_settings_panel)
		xr_settings_panel.setup(quad, mat, xr_camera, xr_origin, composition_video, xr_environment_video)

	# 基准模式保持可见；XR 模式不能最小化，否则 Windows 会把进程降频。
	# 将普通 Godot 窗口移出桌面，既不进入桌面捕获，也不触发最小化节流。
	if "--benchmark-window" in args:
		print("[VR3D] 基准模式：窗口保持可见，禁用最小化降频")
	elif xr_active:
		get_window().mode = Window.MODE_WINDOWED
		get_window().position = Vector2i(-32000, -32000)
		print("[VR3D] OpenXR 模式：窗口已移出桌面且不最小化（避免降频/捕获回环）")
	else:
		get_window().mode = Window.MODE_MINIMIZED
		print("[VR3D] Godot 窗口已最小化（防捕获回环）")

	_connect()
	t_last = Time.get_ticks_msec()

func _has_cmdline_prefix(prefix: String) -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return true
	return false

func _create_placeholder_textures() -> void:
	# Shader samplers must always reference valid textures. Limited-range black
	# (Y=16, U=V=128) keeps the screen black until the first network frame.
	var y_image := Image.create(color_w, color_h, false, Image.FORMAT_R8)
	y_image.fill(Color(16.0 / 255.0, 0.0, 0.0, 1.0))
	var uv_w: int = color_w / 2
	var uv_h: int = color_h / 2
	var u_image := Image.create(uv_w, uv_h, false, Image.FORMAT_R8)
	u_image.fill(Color(128.0 / 255.0, 0.0, 0.0, 1.0))
	var v_image := Image.create(uv_w, uv_h, false, Image.FORMAT_R8)
	v_image.fill(Color(128.0 / 255.0, 0.0, 0.0, 1.0))
	var depth_image := Image.create(depth_n, depth_n, false, Image.FORMAT_RF)
	depth_image.fill(Color(0.5, 0.0, 0.0, 1.0))

	color_tex = ImageTexture.create_from_image(y_image)
	u_tex = ImageTexture.create_from_image(u_image)
	v_tex = ImageTexture.create_from_image(v_image)
	depth_tex = ImageTexture.create_from_image(depth_image)
	mat.set_shader_parameter("y_tex", color_tex)
	mat.set_shader_parameter("u_tex", u_tex)
	mat.set_shader_parameter("v_tex", v_tex)
	mat.set_shader_parameter("depth_tex", depth_tex)
	print("[VR3D] placeholder textures ready; waiting for desktop stream")

func _connect() -> void:
	if rx_thread != null:
		return
	rx_mutex.lock()
	rx_stop = false
	rx_mutex.unlock()
	rx_thread = Thread.new()
	var err := rx_thread.start(_receive_loop, Thread.PRIORITY_HIGH)
	if err != OK:
		print("[VR3D] 接收线程启动失败: ", err)
		rx_thread = null

func _should_stop() -> bool:
	rx_mutex.lock()
	var stop := rx_stop
	rx_mutex.unlock()
	return stop

func _read_exact(peer: StreamPeerTCP, size: int) -> PackedByteArray:
	# Keep header reads interruptible while waiting for the next frame.
	var result := PackedByteArray()
	while result.size() < size:
		if _should_stop():
			return PackedByteArray()
		peer.poll()
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			return PackedByteArray()
		var available := peer.get_available_bytes()
		if available <= 0:
			OS.delay_msec(1)
			continue
		var want: int = mini(available, size - result.size())
		var chunk := peer.get_data(want)
		if chunk[0] != OK:
			return PackedByteArray()
		result.append_array(chunk[1])
	return result

func _read_payload_exact(peer: StreamPeerTCP, size: int) -> PackedByteArray:
	# Once the 4-byte header has arrived, Python is already sending the complete
	# frame. This runs on the receiver thread, so an exact blocking read avoids
	# rebuilding a 5.3 MiB array from many small append_array() chunks.
	var packet := peer.get_data(size)
	if packet[0] != OK:
		return PackedByteArray()
	return packet[1]

func _receive_loop() -> void:
	var probe_frames := 0
	var probe_header_us := 0
	var probe_payload_us := 0
	var probe_ack_us := 0
	var probe_started := Time.get_ticks_usec()
	while not _should_stop():
		var stream_color_w := color_w
		var stream_color_h := color_h
		var stream_depth_n := depth_n
		var stream_y_size := stream_color_w * stream_color_h
		var stream_uv_size := (stream_color_w / 2) * (stream_color_h / 2)
		var stream_depth_size := stream_depth_n * stream_depth_n * 4
		var stream_payload_size := stream_y_size + stream_uv_size * 2 + stream_depth_size
		var peer := StreamPeerTCP.new()
		peer.big_endian = false
		var connect_err := peer.connect_to_host("127.0.0.1", server_port)
		if connect_err != OK:
			OS.delay_msec(500)
			continue

		var announced := false
		while not _should_stop():
			peer.poll()
			var status := peer.get_status()
			if status == StreamPeerTCP.STATUS_CONNECTING:
				OS.delay_msec(1)
				continue
			if status != StreamPeerTCP.STATUS_CONNECTED:
				break
			if not announced:
				announced = true
				# A 1-byte ACK must not wait for Nagle to coalesce, otherwise the
				# sender pays an extra RTT on every frame.
				peer.set_no_delay(true)
				var config := _read_exact(peer, STREAM_CONFIG_SIZE)
				if config.size() != STREAM_CONFIG_SIZE:
					print("[VR3D] stream config read failed")
					break
				if config.slice(0, 4).get_string_from_ascii() != STREAM_MAGIC:
					print("[VR3D] unsupported stream magic; Python and Godot versions must match")
					break
				var config_version := int(config.decode_u32(4))
				stream_color_w = int(config.decode_u32(8))
				stream_color_h = int(config.decode_u32(12))
				stream_depth_n = int(config.decode_u32(16))
				if config_version != STREAM_CONFIG_VERSION:
					print("[VR3D] unsupported stream config version=%d" % config_version)
					break
				if stream_color_w < 2 or stream_color_h < 2 or stream_color_w > 16384 or stream_color_h > 16384:
					print("[VR3D] invalid stream resolution=%dx%d" % [stream_color_w, stream_color_h])
					break
				if stream_color_w % 2 != 0 or stream_color_h % 2 != 0:
					print("[VR3D] stream dimensions must be even: %dx%d" % [stream_color_w, stream_color_h])
					break
				if stream_depth_n < 8 or stream_depth_n > 2048:
					print("[VR3D] invalid depth size=%d" % stream_depth_n)
					break
				stream_y_size = stream_color_w * stream_color_h
				stream_uv_size = (stream_color_w / 2) * (stream_color_h / 2)
				stream_depth_size = stream_depth_n * stream_depth_n * 4
				stream_payload_size = stream_y_size + stream_uv_size * 2 + stream_depth_size
				rx_mutex.lock()
				pending_color_w = stream_color_w
				pending_color_h = stream_color_h
				pending_depth_n = stream_depth_n
				pending_stream_config = true
				rx_mutex.unlock()
				print("[VR3D] connected to Python; stream=%dx%d depth=%d payload=%.2f MiB" % [
					stream_color_w,
					stream_color_h,
					stream_depth_n,
					float(stream_payload_size) / 1048576.0,
				])

			var t0 := Time.get_ticks_usec()
			var header := _read_exact(peer, 4)
			if header.size() != 4:
				break
			var frame_len := int(header.decode_u32(0))
			var has_color := frame_len == stream_payload_size
			var has_depth := frame_len == stream_payload_size or frame_len == stream_depth_size
			if frame_len != 0 and not (has_color or has_depth):
				print("[VR3D] bad frame length got=%d want=%d/%d/0" % [frame_len, stream_payload_size, stream_depth_size])
				break

			var t1 := Time.get_ticks_usec()
			var y_bytes := PackedByteArray()
			var u_bytes := PackedByteArray()
			var v_bytes := PackedByteArray()
			var depth_bytes := PackedByteArray()
			if has_color:
				y_bytes = _read_payload_exact(peer, stream_y_size)
				u_bytes = _read_payload_exact(peer, stream_uv_size)
				v_bytes = _read_payload_exact(peer, stream_uv_size)
			if has_depth:
				depth_bytes = _read_payload_exact(peer, stream_depth_size)
			if (has_color and (y_bytes.size() != stream_y_size or u_bytes.size() != stream_uv_size or v_bytes.size() != stream_uv_size)) or (has_depth and depth_bytes.size() != stream_depth_size):
				break
			var t2 := Time.get_ticks_usec()

			rx_mutex.lock()
			if pending_ready and (has_color or has_depth):
				replaced_frames += 1
			if has_color:
				pending_y = y_bytes
				pending_u = u_bytes
				pending_v = v_bytes
				pending_has_color = true
			if has_depth:
				pending_depth = depth_bytes
				pending_has_depth = true
			if has_color or has_depth:
				pending_ready = true
			received_frames += 1
			rx_mutex.unlock()
			# ACK as soon as the whole frame is in the single-slot mailbox; the
			# sender never builds a queue of obsolete frames.
			if peer.put_data(frame_ack) != OK:
				break
			# put_data only fills the send buffer; poll flushes the ACK now.
			peer.poll()
			var t3 := Time.get_ticks_usec()

			if rx_probe:
				probe_frames += 1
				probe_header_us += t1 - t0
				probe_payload_us += t2 - t1
				probe_ack_us += t3 - t2
				var probe_now := Time.get_ticks_usec()
				if probe_now - probe_started >= 2000000 and probe_frames > 0:
					var n := float(probe_frames)
					print("[rx] %.1f fps | header %.2f ms | payload %.2f ms | ack %.2f ms" % [
						n * 1000000.0 / float(probe_now - probe_started),
						float(probe_header_us) / n / 1000.0,
						float(probe_payload_us) / n / 1000.0,
						float(probe_ack_us) / n / 1000.0,
					])
					probe_frames = 0
					probe_header_us = 0
					probe_payload_us = 0
					probe_ack_us = 0
					probe_started = probe_now

		peer.disconnect_from_host()
		if not _should_stop():
			OS.delay_msec(250)

func _process(_delta: float) -> void:
	# 截图诊断必须显式开启；正常路径禁止 GPU→CPU 回读和 PNG 编码。
	var now_ms := Time.get_ticks_msec()
	if now_ms - perf_last_ms >= 2000:
		perf_last_ms = now_ms
		var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var primitives := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		print("[PERF] engine=%.1f fps process=%.2f ms draw_calls=%d primitives=%d" % [Engine.get_frames_per_second(), process_ms, draw_calls, primitives])
	if capture_debug and now_ms - shot_t > 5000:
		shot_t = now_ms
		var img := get_viewport().get_texture().get_image()
		img.save_png("G:/24youxi/VR3D/godot_shot.png")
		print("[VR3D] 已截图（诊断模式）")

	var y_bytes := PackedByteArray()
	var u_bytes := PackedByteArray()
	var v_bytes := PackedByteArray()
	var depth_bytes := PackedByteArray()
	var has_color := false
	var has_depth := false
	var has_stream_config := false
	var config_w := color_w
	var config_h := color_h
	var config_depth := depth_n
	var rx_count := 0
	var dropped_count := 0
	rx_mutex.lock()
	if pending_stream_config:
		has_stream_config = true
		config_w = pending_color_w
		config_h = pending_color_h
		config_depth = pending_depth_n
		pending_stream_config = false
	if pending_ready:
		has_color = pending_has_color
		has_depth = pending_has_depth
		if has_color:
			y_bytes = pending_y
			u_bytes = pending_u
			v_bytes = pending_v
		if has_depth:
			depth_bytes = pending_depth
		pending_ready = false
		pending_has_color = false
		pending_has_depth = false
	rx_count = received_frames
	dropped_count = replaced_frames
	rx_mutex.unlock()

	if has_stream_config:
		_apply_stream_resolution(config_w, config_h, config_depth)
	if not has_color and not has_depth:
		return
	if not solid_mode and not no_texture:
		_apply_update(y_bytes, u_bytes, v_bytes, depth_bytes, has_color, has_depth, rx_count, dropped_count)

func _apply_stream_resolution(width: int, height: int, stream_depth_n: int) -> void:
	if width < 2 or height < 2 or stream_depth_n < 8:
		return
	color_w = width
	color_h = height
	depth_n = stream_depth_n
	y_size = color_w * color_h
	uv_size = (color_w / 2) * (color_h / 2)
	depth_payload_size = depth_n * depth_n * 4
	payload_size = y_size + uv_size * 2 + depth_payload_size
	var aspect := float(color_w) / float(color_h)
	if mat != null:
		mat.set_shader_parameter("transport_aspect", aspect)
		mat.set_shader_parameter("screen_aspect", aspect)
	if xr_settings_panel != null and xr_settings_panel.has_method("set_source_resolution"):
		xr_settings_panel.call("set_source_resolution", color_w, color_h)
	if composition_video != null and composition_video.is_active() and composition_video.has_method("set_source_resolution"):
		composition_video.call("set_source_resolution", color_w, color_h)
	print("[VR3D] transport/canvas resolution=%dx%d aspect=%.5f depth=%d" % [
		color_w, color_h, aspect, depth_n
	])

func _apply_update(y_bytes: PackedByteArray, u_bytes: PackedByteArray, v_bytes: PackedByteArray, depth_bytes: PackedByteArray, has_color: bool, has_depth: bool, rx_count: int, dropped_count: int) -> void:
	var apply_started := Time.get_ticks_usec()
	var uv_w: int = color_w / 2
	var uv_h: int = color_h / 2
	var y_size: int = color_w * color_h
	var uv_size: int = uv_w * uv_h
	var depth_size: int = depth_n * depth_n * 4
	if has_color and (y_bytes.size() != y_size or u_bytes.size() != uv_size or v_bytes.size() != uv_size):
		print("[VR3D] color plane size mismatch")
		return
	if has_depth and depth_bytes.size() != depth_size:
		print("[VR3D] depth plane size mismatch")
		return
	if has_depth and not has_color and (plane_y_image == null or plane_y_image.is_empty()):
		# A depth-only update before the first full frame cannot be shown yet.
		return

	var y_changed := false
	var u_changed := false
	var v_changed := false
	var depth_changed := false
	if has_color:
		y_changed = plane_y_image == null or y_bytes != last_plane_y
		u_changed = plane_u_image == null or u_bytes != last_plane_u
		v_changed = plane_v_image == null or v_bytes != last_plane_v
	if has_depth:
		depth_changed = plane_depth_image == null or depth_bytes != last_plane_depth

	if has_color:
		if y_changed:
			if plane_y_image == null:
				plane_y_image = Image.create_from_data(color_w, color_h, false, Image.FORMAT_R8, y_bytes)
			else:
				plane_y_image.set_data(color_w, color_h, false, Image.FORMAT_R8, y_bytes)
			last_plane_y = y_bytes
		if u_changed:
			if plane_u_image == null:
				plane_u_image = Image.create_from_data(uv_w, uv_h, false, Image.FORMAT_R8, u_bytes)
			else:
				plane_u_image.set_data(uv_w, uv_h, false, Image.FORMAT_R8, u_bytes)
			last_plane_u = u_bytes
		if v_changed:
			if plane_v_image == null:
				plane_v_image = Image.create_from_data(uv_w, uv_h, false, Image.FORMAT_R8, v_bytes)
			else:
				plane_v_image.set_data(uv_w, uv_h, false, Image.FORMAT_R8, v_bytes)
			last_plane_v = v_bytes
	if has_depth:
		if depth_changed:
			if plane_depth_image == null:
				plane_depth_image = Image.create_from_data(depth_n, depth_n, false, Image.FORMAT_RF, depth_bytes)
			else:
				plane_depth_image.set_data(depth_n, depth_n, false, Image.FORMAT_RF, depth_bytes)
			last_plane_depth = depth_bytes

	if plane_y_image == null or plane_y_image.is_empty() or plane_u_image == null or plane_u_image.is_empty() or plane_v_image == null or plane_v_image.is_empty() or plane_depth_image == null or plane_depth_image.is_empty():
		print("[VR3D] image plane unavailable")
		return

	if has_color:
		if color_tex == null or Vector2i(color_tex.get_size()) != Vector2i(color_w, color_h):
			color_tex = ImageTexture.create_from_image(plane_y_image)
			mat.set_shader_parameter("y_tex", color_tex)
			print("[VR3D] Y texture created: ", color_tex.get_size())
		elif y_changed:
			color_tex.update(plane_y_image)
		if u_tex == null or Vector2i(u_tex.get_size()) != Vector2i(color_w / 2, color_h / 2):
			u_tex = ImageTexture.create_from_image(plane_u_image)
			mat.set_shader_parameter("u_tex", u_tex)
		elif u_changed:
			u_tex.update(plane_u_image)
		if v_tex == null or Vector2i(v_tex.get_size()) != Vector2i(color_w / 2, color_h / 2):
			v_tex = ImageTexture.create_from_image(plane_v_image)
			mat.set_shader_parameter("v_tex", v_tex)
		elif v_changed:
			v_tex.update(plane_v_image)
	if has_depth:
		if depth_tex == null or Vector2i(depth_tex.get_size()) != Vector2i(depth_n, depth_n):
			depth_tex = ImageTexture.create_from_image(plane_depth_image)
			mat.set_shader_parameter("depth_tex", depth_tex)
			depth_update_count += 1
			print("[VR3D] depth texture created: ", depth_tex.get_size(), " format: ", depth_tex.get_format())
		elif depth_changed:
			depth_tex.update(plane_depth_image)
			depth_update_count += 1

	# Edge-vignette inputs depend only on the current stereo settings. Deriving
	# them from the depth map every frame made the edge warp breathe whenever the
	# sampled edge depths changed; a conservative fixed depth delta keeps the
	# comfort ramp stable while leaving the center 3D unchanged.
	if mat != null:
		var disparity := float(mat.get_shader_parameter("disparity"))
		var convergence := float(mat.get_shader_parameter("convergence"))
		var max_shift_possible := disparity * EDGE_FADE_MAX_DEPTH_DELTA
		var vignette_bias := (convergence - 0.5) * 0.3
		var vignette_start := clampf(lerpf(0.7 - vignette_bias, 1.0 - vignette_bias, clampf(max_shift_possible / 0.05, 0.0, 1.0)), 0.0, 1.0)
		var comfort_width := lerpf(0.06, 0.24, clampf(max_shift_possible / 0.04, 0.0, 1.0))
		mat.set_shader_parameter("vignette_start", vignette_start)
		mat.set_shader_parameter("comfort_width", comfort_width)

	if composition_video != null and composition_video.is_active():
		composition_video.apply_video_textures(color_tex, u_tex, v_tex, depth_tex)

	# Auto convergence follows the median depth of the central desktop region so the
	# main content lands on the zero-parallax plane.
	if has_depth and depth_changed and xr_settings_panel != null and xr_settings_panel.has_method("update_auto_convergence"):
		xr_settings_panel.call("update_auto_convergence", plane_depth_image, depth_n)

	last_apply_ms = float(Time.get_ticks_usec() - apply_started) / 1000.0
	if capture_debug and (Time.get_ticks_msec() - last_frame_save) > 5000:
		last_frame_save = Time.get_ticks_msec()
		plane_y_image.save_png("G:/24youxi/VR3D/godot_frame.png")

	n_frames += 1
	var now := Time.get_ticks_msec()
	if now - t_last >= 2000:
		var fps := float(n_frames) * 1000.0 / float(now - t_last)
		print("[VR3D] %.1f fps | engine %.1f fps | apply %.1f ms | rx=%d replaced=%d depth_up=%d" % [fps, Engine.get_frames_per_second(), last_apply_ms, rx_count, dropped_count, depth_update_count])
		n_frames = 0
		depth_update_count = 0
		t_last = now

func _exit_tree() -> void:
	# StreamPeerTCP 只由接收线程操作。主线程仅发停止信号并等待，
	# 避免退出时两个线程同时 disconnect 导致原生竞态/崩溃。
	rx_mutex.lock()
	rx_stop = true
	rx_mutex.unlock()
	if rx_thread != null:
		rx_thread.wait_to_finish()
		rx_thread = null


