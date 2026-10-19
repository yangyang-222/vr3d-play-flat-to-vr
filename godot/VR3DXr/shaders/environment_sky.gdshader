shader_type sky;

// 8K 环境视频由 VideoStreamTheora 解码后直接绑定到这里。
// 不创建 8K SubViewport/RenderTarget，只做等距柱状投影采样。
uniform sampler2D environment_tex : source_color, filter_linear, repeat_enable;
uniform float rotation_radians = 0.0;
uniform float exposure = 1.0;
uniform bool flip_y = false;

void sky() {
	vec3 dir = normalize(EYEDIR);

	// Godot 相机默认朝 -Z；该映射与 PanoramaSkyMaterial 的等距柱状投影一致。
	float u = atan(dir.x, -dir.z) / (2.0 * PI) + 0.5;
	u = fract(u + rotation_radians / (2.0 * PI));

	float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
	if (flip_y) {
		v = 1.0 - v;
	}

	vec2 uv = vec2(u, clamp(v, 0.0, 1.0));
	COLOR = texture(environment_tex, uv).rgb * exposure;
}