shader_type canvas_item;

// Per-cell liquid FOREGROUND over a SMOOTH refracted background.
//   - air    -> background (image, else bg_color)
//   - solid  -> solid_color,  vacuum -> vacuum_color
//   - liquid -> transparent foreground (density-tinted, ONE colour per cell)
//               composited over the smooth, velocity-offset background.
// Multiphase: the cell's average density (encoded by render.glsl in the A
// channel, 190..250) selects the tint along a blue -> green -> yellow gradient
// (water -> lemon juice -> honey). Mixed cells read as an intermediate colour.
// The background seen through the liquid is sampled at full resolution (NOT
// quantised to cells) so the pseudo-refraction reads properly. Only the liquid's
// own foreground colour + foam is per-cell.
// Foam is a per-cell quantity: the tint lightens with the cell's flow speed and
// thinness (surface / spray); extreme = pure white.

uniform sampler2D fluid_nearest : filter_nearest, repeat_disable; // per-cell data
uniform sampler2D fluid_linear  : filter_linear,  repeat_disable; // smooth vel / coverage
uniform sampler2D bg_tex        : filter_linear,  repeat_enable;

uniform bool  smooth_water = false;  // false = crisp one-colour-per-cell foreground (default)
uniform bool  has_bg = false;
uniform vec4  bg_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4  water_tint : source_color = vec4(0.12, 0.42, 0.85, 1.0);   // water  (A=190)
uniform vec4  lemon_color : source_color = vec4(0.55, 0.85, 0.30, 1.0);  // lemon juice (A=210)
uniform vec4  honey_color : source_color = vec4(0.95, 0.78, 0.18, 1.0);  // honey  (A=230)
uniform float water_opacity : hint_range(0.0, 1.0) = 0.55;
uniform float refraction : hint_range(0.0, 0.2) = 0.03;
uniform vec3  solid_color : source_color = vec3(0.25, 0.25, 0.25);
uniform vec3  vacuum_color : source_color = vec3(0.0, 0.0, 0.0);

// foam: per-cell water-blue -> white
uniform bool  enable_foam = true;
uniform vec4  foam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float foam_amount : hint_range(0.0, 1.0) = 1.0;       // max whiteness (extreme foam)
uniform float foam_speed_gain : hint_range(0.0, 6.0) = 3.5;   // flow speed -> whiter
uniform float foam_edge_base : hint_range(0.0, 1.0) = 0.10;   // base foam on calm thin surface
uniform float foam_depth : hint_range(0.05, 1.0) = 0.45;      // fullness above which foam is suppressed (deep = no foam)

vec3 sample_bg(vec2 uv) {
	return has_bg ? texture(bg_tex, clamp(uv, 0.0, 1.0)).rgb : bg_color.rgb;
}

// Dominant-phase code (A = 190/210/230) -> that liquid's tint. ONE colour/cell.
vec3 phase_tint(int base) {
	int ph = (base - 190) / 20;   // 0 water, 1 lemon, 2 honey
	if (ph <= 0) return water_tint.rgb;
	if (ph == 1) return lemon_color.rgb;
	return honey_color.rgb;
}

void fragment() {
	vec2 uv = UV;
	vec4 d = texture(fluid_nearest, uv);   // per-cell data (nearest)
	int base = int(d.a * 255.0 + 0.5);     // 0 air, 85 solid, 170 vacuum, 190..250 liquid
	float dens = d.r;                      // 0 = no liquid, small = thin, 1 = deep
	vec2 vel = (d.gb - 0.5) * 2.0;         // per-cell velocity (drives foam)

	bool is_liquid = base >= 185;

	// Underlying colour: liquid & air show the smooth background; solid / vacuum
	// are opaque per-cell blocks.
	vec3 col;
	if (is_liquid) {
		col = sample_bg(uv);
	} else if (base > 130) {
		col = vacuum_color;
	} else if (base > 40) {
		col = solid_color;
	} else {
		col = sample_bg(uv);
	}

	if (is_liquid) {
		// Background through the liquid: SMOOTH (full-res) so the pseudo-refraction
		// is not quantised. Offset by the smooth velocity field for cleaner flow.
		vec2 rvel = (texture(fluid_linear, uv).gb - 0.5) * 2.0;
		vec3 refr = sample_bg(uv + rvel * refraction);

		// Foreground: ONE colour per cell = dominant-phase tint faded to foam.
		vec3 fg = phase_tint(base);
		if (enable_foam) {
			float speed = length(vel);
			float thin = 1.0 - smoothstep(0.0, foam_depth, dens);   // 1 at thin/spray, 0 at/above foam_depth
			float foam = clamp((foam_edge_base + speed * foam_speed_gain) * thin * foam_amount, 0.0, 1.0);
			fg = mix(fg, foam_color.rgb, foam);
		}

		// Transparent per-cell foreground over the smooth refracted background.
		vec3 wcol = mix(refr, fg, water_opacity);

		if (smooth_water) {
			float cov = texture(fluid_linear, uv).r;
			col = mix(col, wcol, clamp(cov, 0.0, 1.0));
		} else {
			col = wcol;
		}
	}

	COLOR = vec4(col, 1.0);
}
