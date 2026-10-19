shader_type canvas_item;
render_mode unshaded;

// OpenXR Composition Layer ?????????? SubViewport?
// ???? YUV420 -> RGB ??? DIBR????? 3D ?????
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
uniform float eye_index = 0.0; // 0 = left, 1 = right
uniform bool routing_test = false;

void fragment() {
    if (routing_test) {
        COLOR = vec4(eye_index < 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0), 1.0);
    } else {
    // Canvas and transport share the desktop-derived aspect from stream config.
    // UV maps 1:1 when both values match; the uniforms preserve safe fallback.
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
        float offset = (d - convergence) * disparity;
        float eye = eye_index;
        if (swap_eyes) {
            eye = 1.0 - eye;
        }
        float sign = (eye < 0.5) ? 1.0 : -1.0;
        vec2 eye_uv = clamp(uv + vec2(sign * offset, 0.0), vec2(0.0), vec2(1.0));

        // OpenCV I420 ????? BT.601????????? RGB???
        // ????????CanvasItem ???????????? RGB?
        float y = (texture(y_tex, eye_uv).r * 255.0 - 16.0) / 219.0;
        float u = (texture(u_tex, eye_uv).r * 255.0 - 128.0) / 224.0;
        float v = (texture(v_tex, eye_uv).r * 255.0 - 128.0) / 224.0;
        color = vec3(y + 1.402 * v,
                     y - 0.344136 * u - 0.714136 * v,
                     y + 1.772 * u);
    }

    COLOR = vec4(clamp(color, vec3(0.0), vec3(1.0)), 1.0);
    }
}
