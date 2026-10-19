shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float screen_aspect : hint_range(0.1, 10.0) = 1.7777778;
uniform float transport_aspect : hint_range(0.1, 10.0) = 1.7777778;
uniform sampler2D y_tex : filter_linear;
uniform sampler2D u_tex : filter_linear;
uniform sampler2D v_tex : filter_linear;
uniform sampler2D depth_tex : filter_linear;
uniform float disparity : hint_range(0.0, 0.2) = 0.005;
uniform float convergence : hint_range(0.0, 1.0) = 0.5;
uniform float zoom : hint_range(0.5, 2.0) = 1.0;
uniform bool swap_eyes = false;
uniform float vignette_start : hint_range(0.0, 1.0) = 0.88;
uniform float comfort_width : hint_range(0.0, 0.5) = 0.18;

void fragment() {
    // Physical canvas and transport share the desktop-derived aspect.
    // The uniforms keep a safe fallback if the mesh is edited independently.
    const float SCREEN_ASPECT = 16.0 / 9.0;
    const float TRANSPORT_ASPECT = 16.0 / 9.0;
    float content_height = screen_aspect / max(transport_aspect, 0.0001);
    float content_y0 = (1.0 - content_height) * 0.5;
    vec2 uv = vec2(UV.x, (UV.y - content_y0) / content_height);
    uv = (uv - vec2(0.5)) * zoom + vec2(0.5);
    vec3 color = vec3(0.0);
    if (UV.y >= content_y0 && UV.y <= content_y0 + content_height &&
            uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
        float d = texture(depth_tex, uv).r;
        // Taper disparity toward the horizontal edges. DIBR has no image
        // information beyond the source frame, so a large shift there produces
        // the uncomfortable stretched/clamped border seen at high strength.
        float h_dist = abs(uv.x - 0.5) * 2.0;
        float vignette = 1.0 - smoothstep(vignette_start, 1.0, pow(h_dist, 1.5));
        // High disparity makes the clamped outer border visibly uncomfortable.
        // The CPU derives these from stereo settings only, so the edge ramp
        // stays stable instead of breathing with noisy depth-edge samples.
        float edge_dist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
        float edge_comfort = smoothstep(0.0, comfort_width, edge_dist);
        vignette *= edge_comfort;
        float offset = (d - convergence) * disparity * vignette;
        float eye_index = float(VIEW_INDEX);
        if (swap_eyes) {
            eye_index = 1.0 - eye_index;
        }
        float sign = (eye_index < 0.5) ? 1.0 : -1.0;
        vec2 eye_uv = clamp(uv + vec2(sign * offset, 0.0), vec2(0.0), vec2(1.0));

        // OpenCV COLOR_BGR2YUV_I420 emits studio/limited-range BT.601:
        // Y is 16..235 and U/V are nominally 16..240. Expand it before
        // converting, otherwise black/white become gray and low contrast.
        float y = (texture(y_tex, eye_uv).r * 255.0 - 16.0) / 219.0;
        float u = (texture(u_tex, eye_uv).r * 255.0 - 128.0) / 224.0;
        float v = (texture(v_tex, eye_uv).r * 255.0 - 128.0) / 224.0;
        color = vec3(y + 1.402 * v,
                     y - 0.344136 * u - 0.714136 * v,
                     y + 1.772 * u);
    }

    // YUV reconstructs display/sRGB RGB. Spatial ALBEDO expects linear color.
    vec3 srgb = clamp(color, vec3(0.0), vec3(1.0));
    vec3 linear_color = mix(srgb / 12.92,
        pow((srgb + vec3(0.055)) / 1.055, vec3(2.4)),
        step(vec3(0.04045), srgb));
    ALBEDO = linear_color;
}

