shader_type canvas_item;

// Composites the fluid DATA texture (from render.glsl) over a background:
//   - air cells       -> show the background (image, else bg_color)
//   - solid cells     -> opaque solid_color (crisp blocks, nearest sampling)
//   - vacuum cells    -> opaque vacuum_color
//   - water (coverage) -> semi-transparent tint over a pseudo-refracted
//                         background, offset by the local flow velocity.

// Same fluid texture bound twice: nearest for crisp block boundaries,
// linear for a smooth water edge / refraction.
uniform sampler2D fluid_nearest : filter_nearest, repeat_disable;
uniform sampler2D fluid_linear  : filter_linear,  repeat_disable;
uniform sampler2D bg_tex        : filter_linear,  repeat_enable;

uniform bool  smooth_water = true;   // false -> crisp 10x10 water blocks
uniform bool  has_bg = false;
uniform vec4  bg_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4  water_tint : source_color = vec4(0.12, 0.42, 0.85, 1.0);
uniform float water_opacity : hint_range(0.0, 1.0) = 0.55;
uniform float refraction : hint_range(0.0, 0.2) = 0.03;
uniform vec3  solid_color : source_color = vec3(0.25, 0.25, 0.25);
uniform vec3  vacuum_color : source_color = vec3(0.0, 0.0, 0.0);

vec3 sample_bg(vec2 uv) {
	return has_bg ? texture(bg_tex, clamp(uv, 0.0, 1.0)).rgb : bg_color.rgb;
}

void fragment() {
	vec2 uv = UV;
	vec4 dN = texture(fluid_nearest, uv);
	int base = int(dN.a * 255.0 + 0.5);   // 0 air, 85 solid, 170 vacuum

	vec3 col;
	if (base > 130) {
		col = vacuum_color;                // vacuum
	} else if (base > 40) {
		col = solid_color;                 // solid
	} else {
		col = sample_bg(uv);               // air -> background
	}

	// Water layer (smooth coverage + velocity-driven pseudo-refraction).
	vec4 dL = texture(fluid_linear, uv);
	float water = smooth_water ? dL.r : dN.r;   // linear = soft edge, nearest = crisp blocks
	if (water > 0.02 && base < 40) {
		vec2 vel = (dL.gb - 0.5) * 2.0;                 // [-1,1]
		vec3 refracted = sample_bg(uv + vel * refraction);
		vec3 wcol = mix(refracted, water_tint.rgb, water_opacity);
		col = mix(col, wcol, clamp(water, 0.0, 1.0));
	}

	COLOR = vec4(col, 1.0);
}
