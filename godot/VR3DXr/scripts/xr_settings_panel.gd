extends Node3D

# In-headset settings and controller interaction. The headset runtime still owns
# physical IPD; stereo_strength only changes the generated image disparity.
const CONFIG_PATH := "user://vr3d_settings.cfg"
const BASE_DISPARITY := 0.005
const DEFAULT_SCREEN_ASPECT := 16.0 / 9.0
const DEFAULT_SCREEN_SIZE := Vector2(4.82625, 2.714765625)
const CONFIG_VERSION := 6
const SCREEN_CONFIG_VERSION := 4
const DEFAULT_STEREO_STRENGTH := 1.0
const DEFAULT_CONVERGENCE := 0.50
const MAX_STEREO_STRENGTH := 1.5
const STEREO_STRENGTH_STEP := 0.10
# Mesh projection path is the default renderer since 2026-09-23. These defaults
# place the native 16:9 screen slightly below eye level at a comfortable distance.
const DEFAULT_SCREEN_DISTANCE := 2.4
const DEFAULT_SCREEN_HEIGHT := 1.55
const DEFAULT_SCREEN_CURVATURE := 0.35
const DEFAULT_SCREEN_VERTICAL_STRETCH := 1.00
const MIN_SCREEN_VERTICAL_STRETCH := 1.00
const MAX_SCREEN_VERTICAL_STRETCH := 1.50
const SCREEN_VERTICAL_STRETCH_STEP := 0.05
const ITEM_COUNT := 12
const CONVERGENCE_INDEX := 1
const CURVATURE_INDEX := 5
const VERTICAL_STRETCH_INDEX := 6
const FRAME_RATE_INDEX := 7
const FRAME_RATE_OPTIONS := [60, 90, 120]
const DEFAULT_FRAME_RATE := 90
const SWAP_EYES_INDEX := 8
const BACKGROUND_INDEX := 9
const ROTATION_INDEX := 10
const RESET_INDEX := 11
const BACKGROUND_ROTATION_STEP_DEGREES := 5.0
const CURVE_SEGMENTS := 64
const MAX_CURVE_HALF_ANGLE_DEGREES := 60.0
const AUTO_CONVERGENCE_MIN := 0.15
const AUTO_CONVERGENCE_MAX := 0.85
const AUTO_CONVERGENCE_SMOOTHING := 0.12
const AUTO_CONVERGENCE_SAMPLE_STEP_TARGET := 32
const RESET_CONFIRM_TIMEOUT_MS := 4000
const MAX_LASER_DISTANCE := 10.0
const BUTTON_REVEAL_RATIO := 0.68
const BUTTON_HIDE_GRACE_MS := 350
const CONTROLLER_IDLE_TIMEOUT_MS := 4000
# Pico tracking always contains a little sub-millimetre jitter. Compare poses at
# a fixed interval and require a deliberate 8 mm / 2 degree change so idle
# controllers can actually disappear without making wake-up feel sluggish.
const CONTROLLER_POSE_SAMPLE_INTERVAL_MS := 250
const CONTROLLER_MOVE_EPSILON_SQUARED := 0.000064
const CONTROLLER_ROTATION_DOT_THRESHOLD := 0.99939
const CONTROLLER_AXIS_WAKE_DEADZONE := 0.20
const CONTROLLER_FLOAT_WAKE_DEADZONE := 0.10

var screen_quad: MeshInstance3D
var screen_material: ShaderMaterial
var xr_camera: XRCamera3D
var xr_origin: XROrigin3D
var composition_video = null
var environment_background = null
var saved_environment_mode := "video"
var saved_environment_image_path := ""
var environment_rotation_degrees := 0.0
var environment_settings_applied := false
var base_screen_position := Vector3.ZERO
var base_screen_scale := Vector3.ONE
var base_screen_size := DEFAULT_SCREEN_SIZE
var source_aspect := DEFAULT_SCREEN_ASPECT
var applied_screen_curvature := -1.0
var applied_screen_vertical_stretch := -1.0
var applied_screen_width := -1.0
var applied_screen_height := -1.0

var stereo_strength := 1.0
var convergence := DEFAULT_CONVERGENCE
var auto_convergence := true
var auto_convergence_value := DEFAULT_CONVERGENCE
var screen_distance := 3.0
var screen_scale := 1.0
var screen_height := 1.7
var screen_curvature := 0.0
var screen_vertical_stretch := DEFAULT_SCREEN_VERTICAL_STRETCH
var frame_rate := DEFAULT_FRAME_RATE
var applied_frame_rate := -1
var swap_eyes := false

var panel_viewport: SubViewport
var panel_mesh: MeshInstance3D
var row_panels: Array[PanelContainer] = []
var row_name_labels: Array[Label] = []
var row_value_labels: Array[Label] = []
var description_label: Label
var selected_index := 0
var panel_visible := false
var reset_confirmation_pending := false
var reset_confirmation_deadline_ms := 0

var settings_button_viewport: SubViewport
var settings_button_mesh: MeshInstance3D
var settings_button_panel: PanelContainer
var settings_button_label: Label
var button_hovered := false
var button_hide_after_ms := 0

var controllers: Dictionary = {}
var controller_visuals: Dictionary = {}
var laser_beams: Dictionary = {}
var laser_spots: Dictionary = {}
var hover_targets: Dictionary = {
	"left": {"type": "", "row": -1, "panel_x": 0.0},
	"right": {"type": "", "row": -1, "panel_x": 0.0},
}
var controller_axes := {
	"left": Vector2.ZERO,
	"right": Vector2.ZERO,
}
var last_nav_direction := Vector2i.ZERO
var next_nav_ms := 0
var settings_dirty := false
var dirty_since_ms := 0
var controller_tracking_states: Dictionary = {
	"left": "",
	"right": "",
}
var controller_last_activity_ms: Dictionary = {
	"left": 0,
	"right": 0,
}
var controller_previous_positions: Dictionary = {
	"left": Vector3.ZERO,
	"right": Vector3.ZERO,
}
var controller_previous_directions: Dictionary = {
	"left": Vector3.FORWARD,
	"right": Vector3.FORWARD,
}
var controller_pose_initialized: Dictionary = {
	"left": false,
	"right": false,
}
var controller_last_pose_sample_ms: Dictionary = {
	"left": 0,
	"right": 0,
}
var controller_was_active: Dictionary = {
	"left": false,
	"right": false,
}

func setup(
	p_screen_quad: MeshInstance3D,
	p_material: ShaderMaterial,
	p_camera: XRCamera3D,
	p_origin: XROrigin3D,
	p_composition_video = null,
	p_environment_background = null
) -> void:
	screen_quad = p_screen_quad
	screen_material = p_material
	xr_camera = p_camera
	xr_origin = p_origin
	composition_video = p_composition_video
	environment_background = p_environment_background
	base_screen_position = screen_quad.position
	# Screen geometry owns the native 16:9 dimensions. Keep X/Y scale uniform so
	# a scene edit or inherited transform cannot silently stretch it to ultrawide.
	var uniform_scale := minf(absf(screen_quad.scale.x), absf(screen_quad.scale.y))
	if uniform_scale <= 0.0001:
		uniform_scale = 1.0
	base_screen_scale = Vector3(uniform_scale, uniform_scale, uniform_scale)
	base_screen_size = DEFAULT_SCREEN_SIZE
	source_aspect = DEFAULT_SCREEN_ASPECT
	if screen_quad.mesh is QuadMesh:
		var source_size := (screen_quad.mesh as QuadMesh).size
		if source_size.y > 0.0001:
			base_screen_size.y = source_size.y
			source_aspect = source_size.x / source_size.y
			base_screen_size.x = source_size.y * source_aspect
	# Start from the mesh-era defaults, then let a versioned config override them.
	screen_distance = DEFAULT_SCREEN_DISTANCE
	screen_height = DEFAULT_SCREEN_HEIGHT
	screen_scale = 1.0
	screen_curvature = DEFAULT_SCREEN_CURVATURE
	screen_vertical_stretch = DEFAULT_SCREEN_VERTICAL_STRETCH
	stereo_strength = DEFAULT_STEREO_STRENGTH
	convergence = DEFAULT_CONVERGENCE
	auto_convergence_value = DEFAULT_CONVERGENCE
	swap_eyes = false
	_load_settings()
	_create_panel()
	_create_settings_button()
	_create_controllers()
	_apply_settings()
	var final_width := base_screen_size.x * base_screen_scale.x * screen_scale
	var final_height := base_screen_size.y * base_screen_scale.y * screen_scale * screen_vertical_stretch
	print("[VR3D] virtual screen: %.3f x %.3f m, aspect=%.4f (desktop-native, stretch=%d%%), distance=%.2f m" % [
		final_width, final_height, final_width / maxf(final_height, 0.0001), roundi(screen_vertical_stretch * 100.0), screen_distance
	])
	print("[VR3D] stereo: strength=%d%% disparity=%.4f convergence=%d%% swap_eyes=%s" % [
		roundi(stereo_strength * 100.0), BASE_DISPARITY * stereo_strength, roundi(convergence * 100.0), str(swap_eyes)
	])
	_refresh_ui()
	_set_panel_visible(false)
	_set_settings_button_visible(false)
	print("[VR3D] XR 交互: 双手柄激光指向屏幕底部显示设置按钮；扳机点击开关面板")
	print("[VR3D] XR 设置: 摇杆上下选择、左右调节；Grip 关闭；键盘 F1 调试")

func set_source_resolution(width: int, height: int) -> void:
	if width < 2 or height < 2:
		return
	var new_aspect := float(width) / float(height)
	if is_equal_approx(new_aspect, source_aspect):
		return
	var physical_height := base_screen_size.y
	source_aspect = new_aspect
	base_screen_size.y = physical_height
	base_screen_size.x = physical_height * source_aspect
	_apply_settings()
	_refresh_ui()
	print("[VR3D] canvas follows desktop: %dx%d aspect=%.5f size=%.3fx%.3fm" % [
		width, height, source_aspect, base_screen_size.x, base_screen_size.y
	])

func _create_panel() -> void:
	panel_viewport = SubViewport.new()
	panel_viewport.name = "SettingsViewport"
	panel_viewport.size = Vector2i(800, 900)
	panel_viewport.transparent_bg = true
	panel_viewport.disable_3d = true
	panel_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(panel_viewport)

	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background_style := StyleBoxFlat.new()
	background_style.bg_color = Color(0.025, 0.035, 0.055, 0.97)
	background_style.border_color = Color(0.12, 0.72, 0.90, 0.98)
	background_style.set_border_width_all(3)
	background_style.set_corner_radius_all(24)
	background.add_theme_stylebox_override("panel", background_style)
	panel_viewport.add_child(background)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	background.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	margin.add_child(column)

	var title := Label.new()
	title.text = "VR3D 立体设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "激光指向项目并扣扳机；数值项左半区减小、右半区增大"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	column.add_child(subtitle)

	var names := [
		"立体强度（虚拟眼距）",
		"会聚面",
		"屏幕距离",
		"屏幕大小",
		"画面高度",
		"画面曲率",
		"画布竖向拉伸",
		"画面帧率",
		"交换左右眼",
		"环境背景",
		"背景旋转",
		"恢复默认",
	]
	for item_index in range(names.size()):
		var item_name: String = names[item_index]
		var row := PanelContainer.new()
		if item_index == RESET_INDEX:
			row.custom_minimum_size = Vector2(380, 44)
			row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		else:
			row.custom_minimum_size = Vector2(0, 52)
		column.add_child(row)
		row_panels.append(row)

		var row_margin := MarginContainer.new()
		row_margin.add_theme_constant_override("margin_left", 18)
		row_margin.add_theme_constant_override("margin_right", 18)
		row_margin.add_theme_constant_override("margin_top", 7)
		row_margin.add_theme_constant_override("margin_bottom", 7)
		row.add_child(row_margin)

		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 16)
		row_margin.add_child(line)

		var name_label := Label.new()
		name_label.text = item_name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 22 if item_index == RESET_INDEX else 25)
		line.add_child(name_label)
		row_name_labels.append(name_label)

		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(160, 0)
		value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		value_label.clip_text = true
		value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.add_theme_font_size_override("font_size", 23 if item_index == RESET_INDEX else 27)
		line.add_child(value_label)
		row_value_labels.append(value_label)

	description_label = Label.new()
	description_label.custom_minimum_size = Vector2(0, 48)
	description_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.add_theme_font_size_override("font_size", 18)
	description_label.add_theme_color_override("font_color", Color(0.76, 0.86, 0.92))
	column.add_child(description_label)

	var hint := Label.new()
	hint.text = "摇杆 ↑↓ 选择  ←→ 调节    扳机确认    Grip 关闭\n屏幕底部的按钮可开关设置面板    键盘 F1 可调试"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 17)
	hint.add_theme_color_override("font_color", Color(0.62, 0.68, 0.76))
	column.add_child(hint)

	panel_mesh = MeshInstance3D.new()
	panel_mesh.name = "XRSettingsPanel"
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.44, 2.72)
	panel_mesh.mesh = mesh
	# This is a child of the virtual screen, not the headset camera. It stays in
	# the same world-space reference frame as the image.
	panel_mesh.position = Vector3(0.0, 0.14, 0.040)
	panel_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	material.no_depth_test = true
	material.albedo_texture = panel_viewport.get_texture()
	panel_mesh.material_override = material
	screen_quad.add_child(panel_mesh)

func _create_settings_button() -> void:
	settings_button_viewport = SubViewport.new()
	settings_button_viewport.name = "SettingsButtonViewport"
	settings_button_viewport.size = Vector2i(512, 128)
	settings_button_viewport.transparent_bg = true
	settings_button_viewport.disable_3d = true
	settings_button_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(settings_button_viewport)

	settings_button_panel = PanelContainer.new()
	settings_button_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	settings_button_viewport.add_child(settings_button_panel)

	settings_button_label = Label.new()
	settings_button_label.text = "VR3D 设置"
	settings_button_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	settings_button_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	settings_button_label.add_theme_font_size_override("font_size", 42)
	settings_button_label.add_theme_color_override("font_color", Color.WHITE)
	settings_button_panel.add_child(settings_button_label)

	settings_button_mesh = MeshInstance3D.new()
	settings_button_mesh.name = "XRSettingsToggleButton"
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.18, 0.295)
	settings_button_mesh.mesh = mesh
	settings_button_mesh.position = Vector3(0.0, -1.48, 0.045)
	settings_button_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	material.no_depth_test = true
	material.albedo_texture = settings_button_viewport.get_texture()
	settings_button_mesh.material_override = material
	screen_quad.add_child(settings_button_mesh)
	_refresh_settings_button(false)

func _create_controllers() -> void:
	for side in ["left", "right"]:
		var controller := XRController3D.new()
		controller.name = "VR3DController%s" % side.capitalize()
		controller.tracker = &"left_hand" if side == "left" else &"right_hand"
		controller.pose = &"default"
		xr_origin.add_child(controller)
		controller.button_pressed.connect(_on_controller_button_pressed.bind(side))
		controller.input_vector2_changed.connect(_on_controller_vector2_changed.bind(side))
		controller.input_float_changed.connect(_on_controller_float_changed.bind(side))
		controllers[side] = controller
		_create_controller_visual(controller, side)

func _create_controller_visual(controller: XRController3D, side: String) -> void:
	var root := Node3D.new()
	root.name = "VisibleController"
	controller.add_child(root)
	controller_visuals[side] = root

	var hand_color := Color(0.12, 0.58, 1.0) if side == "left" else Color(1.0, 0.38, 0.12)
	var hand_material := StandardMaterial3D.new()
	hand_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hand_material.albedo_color = hand_color
	hand_material.emission_enabled = true
	hand_material.emission = hand_color
	hand_material.emission_energy_multiplier = 0.35

	# A compact procedural controller model avoids relying on vendor model assets.
	var grip := MeshInstance3D.new()
	grip.name = "Grip"
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.075, 0.13, 0.16)
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.055, 0.075)
	grip.rotation_degrees.x = -18.0
	grip.material_override = hand_material
	root.add_child(grip)

	var head := MeshInstance3D.new()
	head.name = "ControllerHead"
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.115, 0.055, 0.105)
	head.mesh = head_mesh
	head.position = Vector3(0.0, 0.018, 0.005)
	head.material_override = hand_material
	root.add_child(head)

	var laser_material := StandardMaterial3D.new()
	laser_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	laser_material.albedo_color = Color(hand_color.r, hand_color.g, hand_color.b, 0.92)
	laser_material.emission_enabled = true
	laser_material.emission = hand_color
	laser_material.emission_energy_multiplier = 2.0
	laser_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	laser_material.no_depth_test = true

	var beam := MeshInstance3D.new()
	beam.name = "LaserBeam"
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.008, 0.008, 1.0)
	beam.mesh = beam_mesh
	beam.position = Vector3(0.0, 0.0, -MAX_LASER_DISTANCE * 0.5)
	beam.scale = Vector3(1.0, 1.0, MAX_LASER_DISTANCE)
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.material_override = laser_material
	controller.add_child(beam)
	laser_beams[side] = beam

	var spot := MeshInstance3D.new()
	spot.name = "LaserSpot"
	var spot_mesh := SphereMesh.new()
	spot_mesh.radius = 0.018
	spot_mesh.height = 0.036
	spot.mesh = spot_mesh
	spot.position = Vector3(0.0, 0.0, -MAX_LASER_DISTANCE)
	spot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spot.material_override = laser_material
	controller.add_child(spot)
	laser_spots[side] = spot

	root.visible = false
	beam.visible = false
	spot.visible = false

func _on_controller_button_pressed(button_name: StringName, side: String) -> void:
	_mark_controller_activity(side)
	var button := String(button_name)
	if button == "menu_button" or button == "by_button":
		_toggle_panel()
		return
	if button == "grip_click":
		if panel_visible:
			_set_panel_visible(false)
		return
	if button != "trigger_click" and button != "ax_button" and button != "primary_click":
		return

	var target: Dictionary = hover_targets.get(side, {"type": "", "row": -1, "panel_x": 0.0})
	var target_type := String(target.get("type", ""))
	if target_type == "button":
		_toggle_panel()
		return
	if not panel_visible:
		return
	if target_type == "row":
		_select_index(clampi(int(target.get("row", 0)), 0, ITEM_COUNT - 1))
		if selected_index <= VERTICAL_STRETCH_INDEX or selected_index == BACKGROUND_INDEX or selected_index == ROTATION_INDEX:
			_adjust_selected(-1 if float(target.get("panel_x", 0.0)) < 0.0 else 1)
		else:
			_activate_selected()
		return
	_activate_selected()

func _on_controller_vector2_changed(input_name: StringName, value: Vector2, side: String) -> void:
	if value.length() >= CONTROLLER_AXIS_WAKE_DEADZONE:
		_mark_controller_activity(side)
	if String(input_name) == "primary":
		controller_axes[side] = value

func _on_controller_float_changed(_input_name: StringName, value: float, side: String) -> void:
	if absf(value) >= CONTROLLER_FLOAT_WAKE_DEADZONE:
		_mark_controller_activity(side)

func _mark_controller_activity(side: String) -> void:
	controller_last_activity_ms[side] = Time.get_ticks_msec()

func _process(_delta: float) -> void:
	if settings_dirty and Time.get_ticks_msec() - dirty_since_ms >= 500:
		_save_settings()
	_update_reset_confirmation()

	_update_controller_pointers()
	_update_thumbstick_navigation()

func _update_controller_pointers() -> void:
	var reveal_button := false
	var any_button_hover := false
	var hovered_row := -1

	for side in ["left", "right"]:
		var controller := controllers.get(side) as XRController3D
		var visual := controller_visuals.get(side) as Node3D
		var beam := laser_beams.get(side) as MeshInstance3D
		var spot := laser_spots.get(side) as MeshInstance3D
		if controller == null or visual == null or beam == null or spot == null:
			continue

		var active := controller.get_is_active()
		var tracked := controller.get_has_tracking_data()
		var tracking_state := "active=%s tracked=%s pose=%s" % [
			active,
			tracked,
			String(controller.pose),
		]
		if String(controller_tracking_states.get(side, "")) != tracking_state:
			controller_tracking_states[side] = tracking_state
			print("[VR3D] OpenXR %s controller: %s" % [side, tracking_state])

		var position := controller.global_position
		var direction := -controller.global_transform.basis.z.normalized()
		var now := Time.get_ticks_msec()
		var pose_available := active and tracked
		var pose_initialized := bool(controller_pose_initialized.get(side, false))
		var was_active := bool(controller_was_active.get(side, false))
		if pose_available:
			if not was_active or not pose_initialized:
				_mark_controller_activity(side)
				controller_previous_positions[side] = position
				controller_previous_directions[side] = direction
				controller_last_pose_sample_ms[side] = now
			elif now - int(controller_last_pose_sample_ms.get(side, 0)) >= CONTROLLER_POSE_SAMPLE_INTERVAL_MS:
				var previous_position: Vector3 = controller_previous_positions.get(side, position)
				var previous_direction: Vector3 = controller_previous_directions.get(side, direction)
				if position.distance_squared_to(previous_position) >= CONTROLLER_MOVE_EPSILON_SQUARED \
						or direction.dot(previous_direction) <= CONTROLLER_ROTATION_DOT_THRESHOLD:
					_mark_controller_activity(side)
				controller_previous_positions[side] = position
				controller_previous_directions[side] = direction
				controller_last_pose_sample_ms[side] = now
		else:
			controller_last_pose_sample_ms[side] = now
		controller_pose_initialized[side] = pose_available
		controller_was_active[side] = pose_available

		var last_activity := int(controller_last_activity_ms.get(side, 0))
		var recently_used := pose_available and now - last_activity <= CONTROLLER_IDLE_TIMEOUT_MS
		visual.visible = recently_used
		beam.visible = recently_used
		if not recently_used:
			spot.visible = false
			hover_targets[side] = {"type": "", "row": -1, "panel_x": 0.0}
			continue

		var hit := _ray_to_screen(position, direction)
		var laser_length := MAX_LASER_DISTANCE
		if bool(hit.get("hit", false)):
			laser_length = minf(float(hit.get("distance", MAX_LASER_DISTANCE)), MAX_LASER_DISTANCE)
			spot.visible = true
			spot.position = Vector3(0.0, 0.0, -laser_length)
			var screen_local: Vector3 = hit.get("local", Vector3.ZERO)
			var screen_half := _screen_half_size()
			if screen_local.y <= -screen_half.y * BUTTON_REVEAL_RATIO:
				reveal_button = true

			if _point_hits_button(screen_local):
				hover_targets[side] = {"type": "button", "row": -1, "panel_x": 0.0}
				any_button_hover = true
			elif panel_visible:
				var panel_hit := _panel_hit_test(screen_local)
				if bool(panel_hit.get("hit", false)):
					var row := int(panel_hit.get("row", -1))
					hover_targets[side] = {
						"type": "row" if row >= 0 else "panel",
						"row": row,
						"panel_x": float(panel_hit.get("x", 0.0)),
					}
					if row >= 0 and hovered_row < 0:
						hovered_row = row
				else:
					hover_targets[side] = {"type": "", "row": -1, "panel_x": 0.0}
			else:
				hover_targets[side] = {"type": "", "row": -1, "panel_x": 0.0}
		else:
			spot.visible = false
			hover_targets[side] = {"type": "", "row": -1, "panel_x": 0.0}

		_set_laser_length(beam, laser_length)

	if hovered_row >= 0 and hovered_row != selected_index:
		_select_index(hovered_row)

	var now := Time.get_ticks_msec()
	if reveal_button:
		button_hide_after_ms = now + BUTTON_HIDE_GRACE_MS
	var should_show_button := reveal_button or now <= button_hide_after_ms
	_set_settings_button_visible(should_show_button)
	if any_button_hover != button_hovered:
		button_hovered = any_button_hover
		_refresh_settings_button(button_hovered)

func _set_laser_length(beam: MeshInstance3D, laser_length: float) -> void:
	var safe_length := clampf(laser_length, 0.03, MAX_LASER_DISTANCE)
	beam.position = Vector3(0.0, 0.0, -safe_length * 0.5)
	beam.scale = Vector3(1.0, 1.0, safe_length)

func _ray_to_screen(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	if screen_quad == null or screen_quad.mesh == null:
		return {"hit": false}

	# Perform the hit test in screen-local space. For a curved screen this uses
	# the exact cylinder used by _build_curved_screen_mesh(), not the old centre
	# plane approximation, so the laser dot remains attached to the visible arc.
	var inverse_basis := screen_quad.global_transform.basis.inverse()
	var local_origin := screen_quad.to_local(ray_origin)
	var local_direction := inverse_basis * ray_direction
	var half_size := _screen_half_size()
	var local_hit := Vector3.ZERO
	var found_hit := false
	var half_angle := deg_to_rad(MAX_CURVE_HALF_ANGLE_DEGREES) * clampf(screen_curvature, 0.0, 1.0)

	if half_angle <= 0.0001:
		if absf(local_direction.z) < 0.0001:
			return {"hit": false}
		var local_t := -local_origin.z / local_direction.z
		if local_t <= 0.0:
			return {"hit": false}
		local_hit = local_origin + local_direction * local_t
		found_hit = absf(local_hit.x) <= half_size.x and absf(local_hit.y) <= half_size.y
	else:
		var radius := half_size.x / sin(half_angle)
		var ox := local_origin.x
		var oz := local_origin.z - radius
		var dx := local_direction.x
		var dz := local_direction.z
		var a := dx * dx + dz * dz
		if a <= 0.0000001:
			return {"hit": false}
		var b := 2.0 * (ox * dx + oz * dz)
		var c := ox * ox + oz * oz - radius * radius
		var discriminant := b * b - 4.0 * a * c
		if discriminant < 0.0:
			return {"hit": false}
		var root := sqrt(discriminant)
		var candidates := PackedFloat32Array([(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)])
		var best_t := INF
		for local_t in candidates:
			if local_t <= 0.0 or local_t >= best_t:
				continue
			var candidate := local_origin + local_direction * local_t
			var candidate_angle := atan2(candidate.x, radius - candidate.z)
			if absf(candidate_angle) <= half_angle + 0.0001 and absf(candidate.y) <= half_size.y:
				best_t = local_t
				local_hit = candidate
				found_hit = true

	if not found_hit:
		return {"hit": false}
	var world_hit := screen_quad.to_global(local_hit)
	var distance := ray_origin.distance_to(world_hit)
	if distance <= 0.02 or distance > MAX_LASER_DISTANCE:
		return {"hit": false}
	return {"hit": true, "distance": distance, "local": local_hit, "world": world_hit}

func _screen_half_size() -> Vector2:
	return Vector2(base_screen_size.x * 0.5, base_screen_size.y * 0.5 * screen_vertical_stretch)

func _point_hits_button(screen_local: Vector3) -> bool:
	if settings_button_mesh == null or not settings_button_mesh.visible:
		return false
	var quad := settings_button_mesh.mesh as QuadMesh
	if quad == null:
		return false
	var delta := Vector2(
		screen_local.x - settings_button_mesh.position.x,
		screen_local.y - settings_button_mesh.position.y
	)
	var half_size := quad.size * 0.5
	return absf(delta.x) <= half_size.x and absf(delta.y) <= half_size.y

func _panel_hit_test(screen_local: Vector3) -> Dictionary:
	if panel_mesh == null or not panel_visible:
		return {"hit": false}
	var quad := panel_mesh.mesh as QuadMesh
	if quad == null:
		return {"hit": false}
	var delta := Vector2(screen_local.x - panel_mesh.position.x, screen_local.y - panel_mesh.position.y)
	var half_size := quad.size * 0.5
	if absf(delta.x) > half_size.x or absf(delta.y) > half_size.y:
		return {"hit": false}

	var uv := Vector2(delta.x / quad.size.x + 0.5, 0.5 - delta.y / quad.size.y)
	var pixel := Vector2(uv.x * panel_viewport.size.x, uv.y * panel_viewport.size.y)
	var row_index := -1
	for index in range(row_panels.size()):
		if row_panels[index].get_global_rect().has_point(pixel):
			row_index = index
			break
	return {"hit": true, "row": row_index, "x": delta.x}

func _update_thumbstick_navigation() -> void:
	if not panel_visible:
		last_nav_direction = Vector2i.ZERO
		next_nav_ms = 0
		return

	var left_axis: Vector2 = controller_axes["left"]
	var right_axis: Vector2 = controller_axes["right"]
	var axis := left_axis if left_axis.length_squared() >= right_axis.length_squared() else right_axis
	var direction := Vector2i.ZERO
	if absf(axis.y) >= absf(axis.x) and absf(axis.y) >= 0.55:
		direction.y = -1 if axis.y > 0.0 else 1
	elif absf(axis.x) >= 0.55:
		direction.x = 1 if axis.x > 0.0 else -1

	if direction == Vector2i.ZERO:
		last_nav_direction = Vector2i.ZERO
		next_nav_ms = 0
		return

	var now := Time.get_ticks_msec()
	if direction != last_nav_direction:
		_handle_nav(direction)
		last_nav_direction = direction
		next_nav_ms = now + 360
	elif now >= next_nav_ms:
		_handle_nav(direction)
		next_nav_ms = now + 110

func _handle_nav(direction: Vector2i) -> void:
	if direction.y != 0:
		_select_index(posmod(selected_index + direction.y, ITEM_COUNT))
	elif direction.x != 0:
		_adjust_selected(direction.x)

func _select_index(index: int) -> void:
	var target_index := clampi(index, 0, ITEM_COUNT - 1)
	if target_index != selected_index and reset_confirmation_pending:
		_cancel_reset_confirmation(false)
	selected_index = target_index
	if target_index == BACKGROUND_INDEX and environment_background != null:
		# 进入环境背景行时重新扫描目录，运行期间新放入的本地图片无需重启。
		environment_background.refresh_background_choices()
	_refresh_ui()

func _cycle_frame_rate(direction: int) -> void:
	var option_index := FRAME_RATE_OPTIONS.find(frame_rate)
	if option_index < 0:
		option_index = FRAME_RATE_OPTIONS.find(DEFAULT_FRAME_RATE)
	option_index = posmod(option_index + direction, FRAME_RATE_OPTIONS.size())
	frame_rate = int(FRAME_RATE_OPTIONS[option_index])

func _adjust_selected(direction: int) -> void:
	match selected_index:
		0:
			stereo_strength = clampf(stereo_strength + STEREO_STRENGTH_STEP * direction, 0.0, MAX_STEREO_STRENGTH)
		CONVERGENCE_INDEX:
			auto_convergence = false
			convergence = clampf(convergence + 0.01 * direction, 0.20, 0.80)
		2:
			screen_distance = clampf(screen_distance + 0.10 * direction, 1.5, 6.0)
		3:
			screen_scale = clampf(screen_scale + 0.05 * direction, 0.60, 1.60)
		4:
			screen_height = clampf(screen_height + 0.10 * direction, 0.50, 3.00)
		CURVATURE_INDEX:
			screen_curvature = clampf(screen_curvature + 0.05 * direction, 0.0, 1.0)
		VERTICAL_STRETCH_INDEX:
			screen_vertical_stretch = clampf(screen_vertical_stretch + SCREEN_VERTICAL_STRETCH_STEP * direction, MIN_SCREEN_VERTICAL_STRETCH, MAX_SCREEN_VERTICAL_STRETCH)
		FRAME_RATE_INDEX:
			_cycle_frame_rate(direction)
		SWAP_EYES_INDEX:
			swap_eyes = not swap_eyes
		BACKGROUND_INDEX:
			if environment_background != null:
				environment_background.cycle_background_choice(direction)
				_mark_dirty()
				_refresh_ui()
			return
		ROTATION_INDEX:
			environment_rotation_degrees = wrapf(environment_rotation_degrees + BACKGROUND_ROTATION_STEP_DEGREES * direction, -180.0, 180.0)
		RESET_INDEX:
			return
	_apply_settings()
	_mark_dirty()
	_refresh_ui()

func _activate_selected() -> void:
	if selected_index == CONVERGENCE_INDEX:
		auto_convergence = not auto_convergence
		if auto_convergence:
			auto_convergence_value = convergence
		_apply_settings()
		_mark_dirty()
		_refresh_ui()
	elif selected_index == SWAP_EYES_INDEX:
		swap_eyes = not swap_eyes
		_apply_settings()
		_mark_dirty()
		_refresh_ui()
	elif selected_index == FRAME_RATE_INDEX:
		_adjust_selected(1)
	elif selected_index == BACKGROUND_INDEX:
		if environment_background != null:
			environment_background.cycle_background_choice(1)
			_mark_dirty()
			_refresh_ui()
	elif selected_index == RESET_INDEX:
		_request_reset_defaults()

func _request_reset_defaults() -> void:
	var now := Time.get_ticks_msec()
	if reset_confirmation_pending and now <= reset_confirmation_deadline_ms:
		reset_confirmation_pending = false
		reset_confirmation_deadline_ms = 0
		_reset_defaults()
		return
	reset_confirmation_pending = true
	reset_confirmation_deadline_ms = now + RESET_CONFIRM_TIMEOUT_MS
	_refresh_ui()

func _update_reset_confirmation() -> void:
	if reset_confirmation_pending and Time.get_ticks_msec() > reset_confirmation_deadline_ms:
		_cancel_reset_confirmation()

func _cancel_reset_confirmation(refresh_ui: bool = true) -> void:
	if not reset_confirmation_pending:
		return
	reset_confirmation_pending = false
	reset_confirmation_deadline_ms = 0
	if refresh_ui:
		_refresh_ui()

func _reset_defaults() -> void:
	stereo_strength = DEFAULT_STEREO_STRENGTH
	convergence = DEFAULT_CONVERGENCE
	auto_convergence = true
	auto_convergence_value = DEFAULT_CONVERGENCE
	screen_distance = DEFAULT_SCREEN_DISTANCE
	screen_scale = 1.0
	screen_height = DEFAULT_SCREEN_HEIGHT
	screen_curvature = DEFAULT_SCREEN_CURVATURE
	screen_vertical_stretch = DEFAULT_SCREEN_VERTICAL_STRETCH
	frame_rate = DEFAULT_FRAME_RATE
	swap_eyes = false
	environment_rotation_degrees = 0.0
	if environment_background != null:
		environment_background.use_default_background()
	_apply_settings()
	_mark_dirty()
	_refresh_ui()

func _choose_display_refresh_rate(available: Variant, target_fps: int) -> float:
	if available == null:
		return 0.0
	var best_rate := 0.0
	var best_distance := 1.0e20
	for value in available:
		var rate := float(value)
		if rate <= 0.0:
			continue
		var distance := absf(rate - float(target_fps))
		if distance < best_distance:
			best_distance = distance
			best_rate = rate
	return best_rate

func _apply_frame_rate() -> void:
	var safe_fps := int(clampf(float(frame_rate), float(FRAME_RATE_OPTIONS[0]), float(FRAME_RATE_OPTIONS[FRAME_RATE_OPTIONS.size() - 1])))
	if applied_frame_rate == safe_fps:
		return
	Engine.max_fps = safe_fps
	applied_frame_rate = safe_fps
	var xr := XRServer.get_primary_interface()
	if xr != null and xr.is_initialized() and xr.has_method("get_available_display_refresh_rates") and xr.has_method("set_display_refresh_rate"):
		var available: Variant = xr.call("get_available_display_refresh_rates")
		var display_rate := _choose_display_refresh_rate(available, safe_fps)
		if display_rate > 0.0:
			xr.call("set_display_refresh_rate", display_rate)
			print("[VR3D] frame rate target=%d fps, OpenXR display=%.1f Hz" % [safe_fps, display_rate])
			return
	print("[VR3D] frame rate target=%d fps (no OpenXR refresh override)" % safe_fps)

func _apply_settings() -> void:
	_apply_frame_rate()
	if screen_material != null:
		screen_material.set_shader_parameter("disparity", BASE_DISPARITY * stereo_strength)
		screen_material.set_shader_parameter("convergence", convergence)
		screen_material.set_shader_parameter("swap_eyes", swap_eyes)
		screen_material.set_shader_parameter("screen_aspect", source_aspect)
		screen_material.set_shader_parameter("transport_aspect", source_aspect)
	if composition_video != null and composition_video.is_active():
		composition_video.set_stereo_params(BASE_DISPARITY * stereo_strength, convergence, 1.0, swap_eyes)
	if screen_quad != null:
		screen_quad.position = Vector3(base_screen_position.x, screen_height, -screen_distance)
		screen_quad.scale = base_screen_scale * screen_scale
		_apply_screen_curvature()
		if settings_button_mesh != null:
			settings_button_mesh.position.y = -_screen_half_size().y + 0.2075
	if composition_video != null and composition_video.is_active():
		composition_video.set_curvature(screen_curvature)
		composition_video.set_vertical_stretch(screen_vertical_stretch)
		composition_video.sync_screen_transform()
	if environment_background != null:
		if environment_background.has_cli_rotation_override():
			environment_rotation_degrees = environment_background.get_background_rotation_degrees()
		else:
			environment_background.set_background_rotation_degrees(environment_rotation_degrees)
	if not environment_settings_applied and environment_background != null:
		environment_settings_applied = true
		if not environment_background.has_cli_override():
			environment_background.apply_saved_choice(saved_environment_mode, saved_environment_image_path)

func _apply_screen_curvature(force: bool = false) -> void:
	if screen_quad == null:
		return
	if not force and is_equal_approx(applied_screen_curvature, screen_curvature) and is_equal_approx(applied_screen_vertical_stretch, screen_vertical_stretch) and is_equal_approx(applied_screen_width, base_screen_size.x) and is_equal_approx(applied_screen_height, base_screen_size.y):
		return
	screen_quad.mesh = _build_curved_screen_mesh(screen_curvature, screen_vertical_stretch)
	applied_screen_curvature = screen_curvature
	applied_screen_vertical_stretch = screen_vertical_stretch
	applied_screen_width = base_screen_size.x
	applied_screen_height = base_screen_size.y

func _build_curved_screen_mesh(curvature: float, vertical_stretch: float = 1.0) -> ArrayMesh:
	var safe_curvature := clampf(curvature, 0.0, 1.0)
	var safe_stretch := clampf(vertical_stretch, MIN_SCREEN_VERTICAL_STRETCH, MAX_SCREEN_VERTICAL_STRETCH)
	var half_width := base_screen_size.x * 0.5
	var half_height := base_screen_size.y * 0.5 * safe_stretch
	var half_angle := deg_to_rad(MAX_CURVE_HALF_ANGLE_DEGREES) * safe_curvature
	var radius := 0.0
	if half_angle > 0.0001:
		radius = half_width / sin(half_angle)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for column in range(CURVE_SEGMENTS + 1):
		var t := float(column) / float(CURVE_SEGMENTS)
		var normalized_x := t * 2.0 - 1.0
		var angle := normalized_x * half_angle
		var x := normalized_x * half_width
		var z := 0.0
		if half_angle > 0.0001:
			x = sin(angle) * radius
			z = radius * (1.0 - cos(angle))
		var normal := Vector3(-sin(angle), 0.0, cos(angle)).normalized()
		vertices.append(Vector3(x, -half_height, z))
		vertices.append(Vector3(x, half_height, z))
		normals.append(normal)
		normals.append(normal)
		uvs.append(Vector2(t, 1.0))
		uvs.append(Vector2(t, 0.0))

	for column in range(CURVE_SEGMENTS):
		var bottom_left := column * 2
		var top_left := bottom_left + 1
		var bottom_right := bottom_left + 2
		var top_right := bottom_left + 3
		indices.append_array(PackedInt32Array([bottom_left, bottom_right, top_right]))
		indices.append_array(PackedInt32Array([bottom_left, top_right, top_left]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var curved_mesh := ArrayMesh.new()
	curved_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return curved_mesh

func _refresh_ui() -> void:
	if row_value_labels.is_empty():
		return
	row_value_labels[0].text = "%d%%" % roundi(stereo_strength * 100.0)
	if auto_convergence:
		row_value_labels[1].text = "自动 %d%%" % roundi(convergence * 100.0)
	else:
		row_value_labels[1].text = "%d%%" % roundi(convergence * 100.0)
	row_value_labels[2].text = "%.1f m" % screen_distance
	row_value_labels[3].text = "%d%%" % roundi(screen_scale * 100.0)
	row_value_labels[4].text = "%.1f m" % screen_height
	row_value_labels[CURVATURE_INDEX].text = "%d%%" % roundi(screen_curvature * 100.0)
	row_value_labels[VERTICAL_STRETCH_INDEX].text = "%d%%" % roundi(screen_vertical_stretch * 100.0)
	row_value_labels[FRAME_RATE_INDEX].text = "%d FPS" % frame_rate
	row_value_labels[SWAP_EYES_INDEX].text = "已开启" if swap_eyes else "关闭"
	row_value_labels[BACKGROUND_INDEX].text = environment_background.get_background_label() if environment_background != null else "不可用"
	row_value_labels[ROTATION_INDEX].text = "%d°" % roundi(environment_rotation_degrees)
	row_value_labels[RESET_INDEX].text = "再次确认" if reset_confirmation_pending else "扣扳机"

	var descriptions := [
		"控制左右眼视差强度；100% 为舒适基准，150% 为更夸张的深度。",
		"零视差平面；扣扳机切换自动会聚，左右可手动微调。",
		"改变虚拟屏幕与玩家的距离，不改变桌面捕获分辨率。",
		"改变虚拟屏幕物理尺寸，不缩放或重采样传输画面。",
		"上下移动屏幕、设置观看中心高度；范围 0.5～3.0 米。",
		"把宽屏弯向观看者；0% 为平面，100% 为最大曲率。",
		"把画布纵向拉高，画面更接近正方形；100% 为原始比例，150% 为最大拉伸。",
		"设置渲染与 OpenXR 目标帧率；设备不支持 120 时会自动选择最接近的刷新率。",
		"如果凹凸方向反了，打开此项交换左右眼视差。",
		(environment_background.get_background_description() if environment_background != null else "composition 路径不支持环境背景。"),
		"水平旋转 360° 背景图片，每档 5°；角度会和图片选择一起保存。",
		"恢复立体、会聚、屏幕位置大小、曲率、左右眼和背景旋转默认值。",
	]
	description_label.text = "请在 4 秒内再次扣扳机确认恢复默认。" if reset_confirmation_pending else descriptions[selected_index]

	for index in range(row_panels.size()):
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(18 if index == RESET_INDEX else 12)
		if index == RESET_INDEX and reset_confirmation_pending:
			style.bg_color = Color(0.58, 0.16, 0.055, 0.98)
			style.border_color = Color(1.0, 0.56, 0.20, 1.0)
			style.set_border_width_all(3)
			row_name_labels[index].add_theme_color_override("font_color", Color.WHITE)
			row_value_labels[index].add_theme_color_override("font_color", Color(1.0, 0.86, 0.54))
		elif index == selected_index:
			style.bg_color = Color(0.06, 0.36, 0.48, 0.96)
			style.border_color = Color(0.30, 0.88, 1.0, 1.0)
			style.set_border_width_all(2)
			row_name_labels[index].add_theme_color_override("font_color", Color.WHITE)
			row_value_labels[index].add_theme_color_override("font_color", Color(0.52, 0.96, 1.0))
		else:
			style.bg_color = Color(0.05, 0.075, 0.11, 0.82)
			row_name_labels[index].add_theme_color_override("font_color", Color(0.84, 0.88, 0.94))
			row_value_labels[index].add_theme_color_override("font_color", Color(0.78, 0.84, 0.90))
		row_panels[index].add_theme_stylebox_override("panel", style)
	if panel_viewport != null:
		panel_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _refresh_settings_button(hovered: bool) -> void:
	if settings_button_panel == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.48, 0.66, 0.98) if hovered else Color(0.025, 0.16, 0.24, 0.94)
	style.border_color = Color(0.58, 0.96, 1.0, 1.0) if hovered else Color(0.18, 0.75, 0.92, 0.98)
	style.set_border_width_all(4 if hovered else 3)
	style.set_corner_radius_all(24)
	settings_button_panel.add_theme_stylebox_override("panel", style)
	settings_button_label.text = "隐藏设置" if panel_visible else "VR3D 设置"
	if settings_button_viewport != null:
		settings_button_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _toggle_panel() -> void:
	_set_panel_visible(not panel_visible)

func _set_panel_visible(enabled: bool) -> void:
	if not enabled:
		_cancel_reset_confirmation(false)
	panel_visible = enabled
	if panel_mesh != null:
		panel_mesh.visible = enabled
	_refresh_settings_button(button_hovered)
	if enabled:
		_refresh_ui()
	else:
		controller_axes["left"] = Vector2.ZERO
		controller_axes["right"] = Vector2.ZERO
		last_nav_direction = Vector2i.ZERO
		if settings_dirty:
			_save_settings()

func _set_settings_button_visible(enabled: bool) -> void:
	if settings_button_mesh != null:
		settings_button_mesh.visible = enabled

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_F1, KEY_TAB:
			_toggle_panel()
		KEY_UP:
			if panel_visible:
				_handle_nav(Vector2i(0, -1))
		KEY_DOWN:
			if panel_visible:
				_handle_nav(Vector2i(0, 1))
		KEY_LEFT:
			if panel_visible:
				_handle_nav(Vector2i(-1, 0))
		KEY_RIGHT:
			if panel_visible:
				_handle_nav(Vector2i(1, 0))
		KEY_ENTER, KEY_KP_ENTER:
			if panel_visible:
				_activate_selected()
		KEY_ESCAPE:
			if panel_visible:
				_set_panel_visible(false)

func _load_settings() -> bool:
	if not FileAccess.file_exists(CONFIG_PATH):
		return false
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return false
	var version := int(config.get_value("meta", "version", 1))
	saved_environment_mode = String(config.get_value("environment", "mode", "video"))
	saved_environment_image_path = String(config.get_value("environment", "image_path", ""))
	environment_rotation_degrees = wrapf(float(config.get_value("environment", "rotation_degrees", 0.0)), -180.0, 180.0)
	frame_rate = int(config.get_value("render", "frame_rate", DEFAULT_FRAME_RATE))
	if not FRAME_RATE_OPTIONS.has(frame_rate):
		frame_rate = DEFAULT_FRAME_RATE
	stereo_strength = clampf(float(config.get_value("stereo", "strength", DEFAULT_STEREO_STRENGTH)), 0.0, MAX_STEREO_STRENGTH)
	convergence = clampf(float(config.get_value("stereo", "convergence", DEFAULT_CONVERGENCE)), 0.20, 0.80)
	swap_eyes = bool(config.get_value("stereo", "swap_eyes", false))
	auto_convergence = bool(config.get_value("stereo", "auto_convergence", true))
	auto_convergence_value = convergence
	if version < 6:
		# Base disparity was rebalanced to the Moonlight XR comfort scale
		# (0.03 -> 0.005); recalibrate old saved stereo instead of keeping a
		# warp that is now far too strong.
		stereo_strength = DEFAULT_STEREO_STRENGTH
		convergence = DEFAULT_CONVERGENCE
		auto_convergence = true
		auto_convergence_value = DEFAULT_CONVERGENCE
		print("[VR3D] settings: stereo rebalanced to Moonlight comfort scale")
		settings_dirty = true
		dirty_since_ms = Time.get_ticks_msec()
	if version < 3:
		var previous_strength := stereo_strength
		stereo_strength = maxf(stereo_strength, DEFAULT_STEREO_STRENGTH)
		if not is_equal_approx(previous_strength, stereo_strength):
			print("[VR3D] settings: stereo strength migrated %d%% -> %d%% for stronger depth" % [
				roundi(previous_strength * 100.0), roundi(stereo_strength * 100.0)
			])
			settings_dirty = true
			dirty_since_ms = Time.get_ticks_msec()
	if version < 2:
		# Screen geometry saved while the composition-layer path was the default
		# does not transfer to the mesh projection path; keep the mesh defaults.
		print("[VR3D] settings: legacy screen values ignored (mesh defaults applied)")
		return true
	screen_distance = clampf(float(config.get_value("screen", "distance", screen_distance)), 1.5, 6.0)
	screen_scale = clampf(float(config.get_value("screen", "scale", 1.0)), 0.60, 1.60)
	screen_height = clampf(float(config.get_value("screen", "height", screen_height)), 0.50, 3.00)
	screen_curvature = clampf(float(config.get_value("screen", "curvature", 0.0)), 0.0, 1.0)
	screen_vertical_stretch = clampf(float(config.get_value("screen", "vertical_stretch", DEFAULT_SCREEN_VERTICAL_STRETCH)), MIN_SCREEN_VERTICAL_STRETCH, MAX_SCREEN_VERTICAL_STRETCH)
	if version < SCREEN_CONFIG_VERSION:
		# Migrate the old 1.43:1 screen configuration to the native 16:9 canvas.
		screen_vertical_stretch = DEFAULT_SCREEN_VERTICAL_STRETCH
		print("[VR3D] settings: screen migrated to native 16:9 (vertical stretch 100%)")
		settings_dirty = true
		dirty_since_ms = Time.get_ticks_msec()
	return true

func _mark_dirty() -> void:
	settings_dirty = true
	dirty_since_ms = Time.get_ticks_msec()

func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("meta", "version", CONFIG_VERSION)
	config.set_value("stereo", "strength", stereo_strength)
	config.set_value("stereo", "convergence", convergence)
	config.set_value("stereo", "swap_eyes", swap_eyes)
	config.set_value("stereo", "auto_convergence", auto_convergence)
	config.set_value("screen", "distance", screen_distance)
	config.set_value("screen", "scale", screen_scale)
	config.set_value("screen", "height", screen_height)
	config.set_value("screen", "curvature", screen_curvature)
	config.set_value("screen", "vertical_stretch", screen_vertical_stretch)
	config.set_value("render", "frame_rate", frame_rate)
	config.set_value("environment", "rotation_degrees", environment_rotation_degrees)
	if environment_background != null:
		config.set_value("environment", "mode", environment_background.get_mode_name())
		config.set_value("environment", "image_path", environment_background.get_current_path())
	var err := config.save(CONFIG_PATH)
	if err == OK:
		settings_dirty = false
	else:
		push_warning("VR3D 设置保存失败: %s" % error_string(err))

func update_auto_convergence(depth_image: Image, depth_grid: int) -> void:
	if not auto_convergence:
		return
	if depth_image == null or depth_grid < 8:
		return
	var band_lo := int(float(depth_grid) * 0.125)
	var band_hi := int(float(depth_grid) * 0.875)
	var step := maxi(1, depth_grid / AUTO_CONVERGENCE_SAMPLE_STEP_TARGET)
	var samples: Array[float] = []
	var x := band_lo
	while x < band_hi:
		var y := band_lo
		while y < band_hi:
			samples.append(depth_image.get_pixel(x, y).r)
			y += step
		x += step
	if samples.is_empty():
		return
	samples.sort()
	var median: float = samples[samples.size() / 2]
	var target := clampf(median, AUTO_CONVERGENCE_MIN, AUTO_CONVERGENCE_MAX)
	auto_convergence_value = lerpf(auto_convergence_value, target, AUTO_CONVERGENCE_SMOOTHING)
	if absf(auto_convergence_value - convergence) < 0.002:
		return
	convergence = auto_convergence_value
	if screen_material != null:
		screen_material.set_shader_parameter("convergence", convergence)
	if composition_video != null and composition_video.is_active():
		composition_video.set_stereo_params(BASE_DISPARITY * stereo_strength, convergence, 1.0, swap_eyes)
	if panel_visible and row_value_labels.size() > CONVERGENCE_INDEX:
		row_value_labels[CONVERGENCE_INDEX].text = "自动 %d%%" % roundi(convergence * 100.0)

func _exit_tree() -> void:
	if settings_dirty:
		_save_settings()
