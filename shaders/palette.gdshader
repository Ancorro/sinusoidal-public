// Inscryption-style post pass: snap dark colors to a fixed palette, leave bright ones alone.
// Hard banded shadows, while lit cards keep their real colors.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform vec3 palette[8];
uniform float dark_cut = 0.42;
uniform float vignette = 0.9;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	if (l < dark_cut) {
		float best = 1e9;
		vec3 snapped = c;
		for (int i = 0; i < 8; i++) {
			vec3 d = c - palette[i];
			float dd = dot(d, d);
			if (dd < best) { best = dd; snapped = palette[i]; }
		}
		c = snapped;
	}
	vec2 uv = SCREEN_UV - 0.5;
	c *= clamp(1.0 - vignette * dot(uv, uv) * 2.0, 0.0, 1.0);
	COLOR = vec4(c, 1.0);
}
