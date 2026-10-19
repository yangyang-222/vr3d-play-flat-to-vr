extends Node3D

# OpenXR composition-layer video path.
#
# The desktop image is rendered into one CanvasItem SubViewport per eye.  Each
# viewport is bound to its own OpenXRCompositionLayerCylinder, so the runtime
# composites the video directly instead of asking the 3D camera to project the
# desktop texture once per eye. The normal Godot projection layer stays
# available for controllers, lasers, and the fixed settings UI.

const DIBR_CANVAS_SHADER := preload("res://shaders/dibr_canvas.gdshader")
const DEFAULT_SOURCE_SIZE := Vector2i(2560, 1440)
const DEFAULT_SOURCE_ASPECT := 16.0 / 9.0
const FLAT_RADIUS_FACTOR := 100.0
const MAX_CURVE_HALF_ANGLE_DEGREES := 60.0
const MIN_RADIUS := 0.5

var screen_quad: MeshInstance3D
var screen_material: Material
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D

var left_layer = null
var right_layer = null
var left_viewport: SubViewport
var right_viewport: SubViewport
var left_material: ShaderMaterial
var right_material: ShaderMaterial

var _base_mesh_size := Vector2(4.82625, 2.714765625)
var _source_size := DEFAULT_SOURCE_SIZE
var _source_aspect := DEFAULT_SOURCE_ASPECT
var _viewport_size := DEFAULT_SOURCE_SIZE
var _viewport_override := false
var _curvature := 0.0
var _vertical_stretch := 1.0
var _active := false
var _enabled := false
var _original_screen_material: Material = null
var _transparent_material: StandardMaterial3D = null

var _placeholder_y: ImageTexture
var _placeholder_u: ImageTexture
var _placeholder_v: ImageTexture
var _placeholder_depth: ImageTexture

var _dump_eyes_requested := false
var _dump_eyes_started_ms := 0
var _dump_eyes_done := false
var _routing_test := false
var live_depth_tex: Texture2D

func setup(
	p_screen_quad: MeshInstance3D,
	p_screen_material: Material,
	p_origin: XROrigin3D,
	p_camera: XRCamera3D
) -> bool:
	screen_quad = p_screen_quad
	screen_material = p_screen_material
	xr_origin = p_origin
	xr_camera = p_camera
	_active = false
	_enabled = false
	_viewport_size = _resolve_viewport_size()

	if screen_quad == null or xr_origin == null:
		print("[COMP] setup failed: missing screen or XR origin")
		return false
	if not ClassDB.class_exists("OpenXRCompositionLayerCylinder"):
		print("[COMP] OpenXRCompositionLayerCylinder class is unavailable")
		return false

	if screen_quad.mesh is QuadMesh:
		var quad_size := (screen_quad.mesh as QuadMesh).size
		if quad_size.x > 0.001 and quad_size.y > 0.001:
			_base_mesh_size = quad_size
	_original_screen_material = screen_quad.material_override
	_create_placeholder_textures()

	if not _create_layers():
		print("[COMP] composition layer creation failed; keeping mesh fallback")
		_destroy_layers()
		return false

	_active = true
	_enabled = true
	_apply_transparent_screen_material()
	_apply_textures_to_materials()
	_set_layer_visibility(true)
	sync_screen_transform()
	print("[COMP] stereo cylinder composition layers active: left=eye1 right=eye2 viewport=%s" % str(_viewport_size))
	return true

func _resolve_viewport_size() -> Vector2i:
	# --comp-viewport=WxH lets the diagnostic harness A/B the composition
	# layer resolution. Normal launches leave it unset so desktop config wins.
	var requested := _source_size
	_viewport_override = false
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--comp-viewport="):
			continue
		var parts := arg.trim_prefix("--comp-viewport=").split("x")
		if parts.size() != 2:
			push_warning("[COMP] ignored malformed --comp-viewport=%s" % arg)
			continue
		var w := int(parts[0])
		var h := int(parts[1])
		if w >= 256 and h >= 256 and w <= 8192 and h <= 8192:
			requested = Vector2i(w, h)
			_viewport_override = true
		else:
			push_warning("[COMP] ignored out-of-range --comp-viewport=%s" % arg)
	return requested

func _create_layers() -> bool:
	left_layer = ClassDB.instantiate("OpenXRCompositionLayerCylinder")
	right_layer = ClassDB.instantiate("OpenXRCompositionLayerCylinder")
	if left_layer == null or right_layer == null:
		return false

	_configure_layer(left_layer, "XR3DCompositionLeft", 1)
	_configure_layer(right_layer, "XR3DCompositionRight", 2)
	xr_origin.add_child(left_layer)
	xr_origin.add_child(right_layer)

	var left_supported := bool(left_layer.call("is_natively_supported"))
	var right_supported := bool(right_layer.call("is_natively_supported"))
	print("[COMP] native cylinder support: left=%s right=%s" % [left_supported, right_supported])
	if not left_supported or not right_supported:
		return false

	var left_result := _create_eye_viewport("XR3DCompositionLeftViewport", 0.0)
	var right_result := _create_eye_viewport("XR3DCompositionRightViewport", 1.0)
	left_viewport = left_result.get("viewport") as SubViewport
	right_viewport = right_result.get("viewport") as SubViewport
	left_material = left_result.get("material") as ShaderMaterial
	right_material = right_result.get("material") as ShaderMaterial
	if left_viewport == null or right_viewport == null or left_material == null or right_material == null:
		return false

	left_layer.call("set_layer_viewport", left_viewport)
	right_layer.call("set_layer_viewport", right_viewport)
	return true

func _configure_layer(layer, layer_name: String, eye_visibility: int) -> void:
	layer.name = layer_name
	layer.visible = false
	layer.call("set_sort_order", -1)
	layer.call("set_enable_hole_punch", false)
	layer.call("set_alpha_blend", false)
	layer.call("set_eye_visibility", eye_visibility)

func _create_eye_viewport(viewport_name: String, eye_index: float) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.size = _viewport_size
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var material := ShaderMaterial.new()
	material.shader = DIBR_CANVAS_SHADER
	material.set_shader_parameter("screen_aspect", _source_aspect)
	material.set_shader_parameter("transport_aspect", _source_aspect)
	material.set_shader_parameter("eye_index", eye_index)
	material.set_shader_parameter("zoom", 1.0)
	material.set_shader_parameter("swap_eyes", false)
	material.set_shader_parameter("disparity", 0.005)
	material.set_shader_parameter("convergence", 0.5)

	var rect := ColorRect.new()
	rect.name = "VideoRect"
	rect.color = Color.WHITE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = material
	viewport.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return {"viewport": viewport, "material": material}

func _create_placeholder_textures() -> void:
	var y_image := Image.create(1, 1, false, Image.FORMAT_R8)
	y_image.fill(Color(16.0 / 255.0, 0.0, 0.0, 1.0))
	var u_image := Image.create(1, 1, false, Image.FORMAT_R8)
	u_image.fill(Color(128.0 / 255.0, 0.0, 0.0, 1.0))
	var v_image := Image.create(1, 1, false, Image.FORMAT_R8)
	v_image.fill(Color(128.0 / 255.0, 0.0, 0.0, 1.0))
	var depth_image := Image.create(1, 1, false, Image.FORMAT_RF)
	depth_image.fill(Color(0.5, 0.0, 0.0, 1.0))
	_placeholder_y = ImageTexture.create_from_image(y_image)
	_placeholder_u = ImageTexture.create_from_image(u_image)
	_placeholder_v = ImageTexture.create_from_image(v_image)
	_placeholder_depth = ImageTexture.create_from_image(depth_image)

func _apply_textures_to_materials() -> void:
	if left_material == null or right_material == null:
		return
	for material in [left_material, right_material]:
		material.set_shader_parameter("y_tex", _placeholder_y)
		material.set_shader_parameter("u_tex", _placeholder_u)
		material.set_shader_parameter("v_tex", _placeholder_v)
		material.set_shader_parameter("depth_tex", _placeholder_depth)

func apply_video_textures(y_tex: Texture2D, u_tex: Texture2D, v_tex: Texture2D, depth_tex: Texture2D) -> void:
	if left_material == null or right_material == null:
		return
	if y_tex != null:
		left_material.set_shader_parameter("y_tex", y_tex)
		right_material.set_shader_parameter("y_tex", y_tex)
	if u_tex != null:
		left_material.set_shader_parameter("u_tex", u_tex)
		right_material.set_shader_parameter("u_tex", u_tex)
	if v_tex != null:
		left_material.set_shader_parameter("v_tex", v_tex)
		right_material.set_shader_parameter("v_tex", v_tex)
	if depth_tex != null:
		live_depth_tex = depth_tex
		left_material.set_shader_parameter("depth_tex", depth_tex)
		right_material.set_shader_parameter("depth_tex", depth_tex)

func set_diagnostics(dump_eyes: bool, routing_test: bool) -> void:
	_dump_eyes_requested = dump_eyes
	_dump_eyes_started_ms = Time.get_ticks_msec()
	_dump_eyes_done = false
	_routing_test = routing_test
	var left_eye := -1.0
	var right_eye := -1.0
	if left_material != null:
		left_eye = float(left_material.get_shader_parameter("eye_index"))
	if right_material != null:
		right_eye = float(right_material.get_shader_parameter("eye_index"))
	var left_visibility := -1
	var right_visibility := -1
	if left_layer != null and left_layer.has_method("get_eye_visibility"):
		left_visibility = int(left_layer.call("get_eye_visibility"))
	if right_layer != null and right_layer.has_method("get_eye_visibility"):
		right_visibility = int(right_layer.call("get_eye_visibility"))
	for material in [left_material, right_material]:
		if material != null:
			material.set_shader_parameter("routing_test", routing_test)
	print("[DIAG] composition: left_eye=%.0f right_eye=%.0f left_visibility=%d right_visibility=%d dump=%s routing=%s" % [
		left_eye, right_eye, left_visibility, right_visibility, str(dump_eyes), str(routing_test)
	])

func _process(_delta: float) -> void:
	if not _dump_eyes_requested or _dump_eyes_done:
		return
	if left_viewport == null or right_viewport == null:
		return
	if Time.get_ticks_msec() - _dump_eyes_started_ms < 3500:
		return
	_dump_eyes_done = true
	_dump_eye_images()

func _dump_eye_images() -> void:
	var left_image := left_viewport.get_texture().get_image()
	var right_image := right_viewport.get_texture().get_image()
	if left_image == null or right_image == null or left_image.is_empty() or right_image.is_empty():
		print("[DIAG] eye dump failed: viewport image is empty")
		return
	left_image.save_png("G:/24youxi/VR3D/.code/eye_left.png")
	right_image.save_png("G:/24youxi/VR3D/.code/eye_right.png")
	if live_depth_tex != null:
		var depth_image := live_depth_tex.get_image()
		if depth_image != null and not depth_image.is_empty():
			depth_image.save_png("G:/24youxi/VR3D/.code/depth_live.png")
			print("[DIAG] depth image size=%s format=%d" % [str(depth_image.get_size()), int(depth_image.get_format())])
	_report_eye_difference(left_image, right_image)

func _report_eye_difference(left_image: Image, right_image: Image) -> void:
	var a := left_image.duplicate()
	var b := right_image.duplicate()
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	var sample_w := 320
	var sample_h := maxi(1, int(round(float(a.get_height()) * float(sample_w) / float(maxi(a.get_width(), 1)))))
	a.resize(sample_w, sample_h, Image.INTERPOLATE_BILINEAR)
	b.resize(sample_w, sample_h, Image.INTERPOLATE_BILINEAR)
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	var diff_sum := 0.0
	var max_diff := 0
	var differing := 0
	var samples := 0
	var i := 0
	while i < da.size():
		var dr := absi(int(da[i]) - int(db[i]))
		var dg := absi(int(da[i + 1]) - int(db[i + 1]))
		var db2 := absi(int(da[i + 2]) - int(db[i + 2]))
		var d := dr + dg + db2
		diff_sum += float(d)
		if d > max_diff:
			max_diff = d
		if d > 0:
			differing += 1
		samples += 1
		i += 4
	var mean_diff := diff_sum / float(maxi(samples, 1))
	var differing_pct := 100.0 * float(differing) / float(maxi(samples, 1))
	print("[DIAG] eye image difference: mean_rgb_sum=%.3f max_rgb_sum=%d differing=%.2f%% samples=%d" % [
		mean_diff, max_diff, differing_pct, samples
	])
	print("[DIAG] eye pngs: G:/24youxi/VR3D/.code/eye_left.png G:/24youxi/VR3D/.code/eye_right.png")

func set_source_resolution(width: int, height: int) -> void:
	if width < 2 or height < 2:
		return
	var new_source_size := Vector2i(width, height)
	var new_aspect := float(width) / float(height)
	_source_size = new_source_size
	_source_aspect = new_aspect
	_base_mesh_size.x = _base_mesh_size.y * _source_aspect
	if not _viewport_override:
		_viewport_size = _source_size
		if left_viewport != null:
			left_viewport.size = _viewport_size
		if right_viewport != null:
			right_viewport.size = _viewport_size
	for material in [left_material, right_material]:
		if material != null:
			material.set_shader_parameter("screen_aspect", _source_aspect)
			material.set_shader_parameter("transport_aspect", _source_aspect)
	sync_screen_transform()
	print("[COMP] source/viewport follows desktop: source=%s viewport=%s aspect=%.5f" % [
		str(_source_size), str(_viewport_size), _source_aspect
	])

func set_stereo_params(disparity: float, convergence: float, zoom: float, swap_eyes: bool) -> void:
	if left_material == null or right_material == null:
		return
	for material in [left_material, right_material]:
		material.set_shader_parameter("disparity", disparity)
		material.set_shader_parameter("convergence", convergence)
		material.set_shader_parameter("zoom", zoom)
		material.set_shader_parameter("swap_eyes", swap_eyes)

func set_curvature(curvature: float) -> void:
	_curvature = clampf(curvature, 0.0, 1.0)
	sync_screen_transform()

func set_vertical_stretch(stretch: float) -> void:
	_vertical_stretch = clampf(stretch, 1.0, 1.5)
	sync_screen_transform()

func sync_screen_transform() -> void:
	if not _active or screen_quad == null or left_layer == null or right_layer == null:
		return
	var screen_basis := screen_quad.global_transform.basis.orthonormalized()
	var screen_position := screen_quad.global_transform.origin
	var screen_forward := -screen_basis.z.normalized()
	var global_scale := screen_quad.global_transform.basis.get_scale()
	var actual_width := maxf(_base_mesh_size.x * absf(global_scale.x), 0.05)
	var actual_height := maxf(_base_mesh_size.y * absf(global_scale.y) * _vertical_stretch, 0.05)
	var aspect := actual_width / actual_height
	if aspect <= 0.01:
		aspect = _source_aspect

	var radius := MIN_RADIUS
	var central_angle := actual_width / radius
	if _curvature <= 0.0001:
		var view_distance := 3.0
		if xr_camera != null:
			view_distance = maxf(xr_camera.global_position.distance_to(screen_position), MIN_RADIUS)
		radius = view_distance * FLAT_RADIUS_FACTOR
		central_angle = actual_width / radius
	else:
		var half_angle := deg_to_rad(MAX_CURVE_HALF_ANGLE_DEGREES) * _curvature
		central_angle = maxf(2.0 * half_angle, 0.0001)
		radius = maxf(actual_width / central_angle, MIN_RADIUS)

	var center := screen_position - screen_forward * radius
	var layer_transform := Transform3D(screen_basis, center)
	for layer in [left_layer, right_layer]:
		layer.call("set_radius", radius)
		layer.call("set_central_angle", central_angle)
		layer.call("set_aspect_ratio", aspect)
		layer.global_transform = layer_transform

func set_enabled(enabled: bool) -> void:
	_enabled = enabled and _active
	_set_layer_visibility(_enabled)
	if screen_quad == null:
		return
	if _enabled:
		_apply_transparent_screen_material()
	else:
		screen_quad.material_override = _original_screen_material if _original_screen_material != null else screen_material

func is_active() -> bool:
	return _active and _enabled

func _set_layer_visibility(enabled: bool) -> void:
	if left_layer != null:
		left_layer.visible = enabled
	if right_layer != null:
		right_layer.visible = enabled
	if left_viewport != null:
		left_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if right_viewport != null:
		right_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED

func _apply_transparent_screen_material() -> void:
	if screen_quad == null:
		return
	if _transparent_material == null:
		_transparent_material = StandardMaterial3D.new()
		_transparent_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_transparent_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_transparent_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_transparent_material.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	screen_quad.material_override = _transparent_material

func _destroy_layers() -> void:
	for layer in [left_layer, right_layer]:
		if layer != null:
			layer.queue_free()
	left_layer = null
	right_layer = null
	for viewport in [left_viewport, right_viewport]:
		if viewport != null:
			viewport.queue_free()
	left_viewport = null
	right_viewport = null
	left_material = null
	right_material = null
