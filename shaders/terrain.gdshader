shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain colour is authored per vertex during meshing (biome, slope, snow,
// river mud). This shader turns that flat vertex paint into readable ground:
// multi-scale cover on flats, grit and striation on cliffs, without texture maps.

uniform float detail_strength : hint_range(0.0, 0.8) = 0.28;
uniform float detail_scale = 0.42;
// Broad cover patches on the ground plane — soft only; hard contrast reads as
// a repeating texture bug rather than soil variation.
uniform float patch_scale = 0.0055;
uniform float patch_strength : hint_range(0.0, 1.0) = 0.38;
uniform vec3 patch_dry : source_color = vec3(1.14, 1.06, 0.82);
uniform vec3 patch_lush : source_color = vec3(0.84, 0.97, 0.84);
// Larger mottling so plains are not one tone across a kilometre.
uniform float macro_scale = 0.0011;
uniform float macro_strength : hint_range(0.0, 0.5) = 0.18;
// Close-up grit / pebble break-up.
uniform float grit_scale = 1.85;
uniform float grit_strength : hint_range(0.0, 0.5) = 0.22;
// Shading bumps only; the mesh stays smooth.
uniform float bump_strength : hint_range(0.0, 1.0) = 0.16;
uniform float cliff_bump_strength : hint_range(0.0, 1.0) = 0.28;
uniform float cliff_striation : hint_range(0.0, 1.0) = 0.35;
// 0 shades normally. 1 shows raw vertex colour unlit, 2 shows the surface
// normal, 3 shows the corridor mask in UV.x (red where 3D relief is suppressed
// for the drainage-surface contract, green where it is free).
uniform int debug_view : hint_range(0, 3) = 0;

varying vec3 world_position;
varying vec3 world_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z
	);
}

float fbm2(vec3 p) {
	return value_noise(p) * 0.66
		+ value_noise(p * 2.03 + vec3(17.1, 9.4, 3.7)) * 0.34;
}

float fbm3(vec3 p) {
	return value_noise(p) * 0.5
		+ value_noise(p * 2.03 + vec3(17.1, 9.4, 3.7)) * 0.33
		+ value_noise(p * 4.12 + vec3(3.2, 28.0, 11.5)) * 0.17;
}

// Soft masks from the authored vertex colour — biomes already baked the hue.
void surface_masks(vec3 c, out float snow, out float grass, out float warm, out float rockish) {
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
	snow = smoothstep(0.72, 0.88, luma) * (1.0 - smoothstep(0.04, 0.14, chroma));
	grass = smoothstep(0.02, 0.12, c.g - max(c.r, c.b) * 0.85) * (1.0 - snow);
	warm = smoothstep(0.02, 0.12, c.r - c.b) * smoothstep(0.02, 0.1, c.r - c.g * 0.55);
	warm *= (1.0 - snow) * (1.0 - grass * 0.65);
	rockish = (1.0 - snow) * (1.0 - grass * 0.7) * (1.0 - warm * 0.5);
	rockish = clamp(rockish + (1.0 - chroma) * 0.25 * (1.0 - snow), 0.0, 1.0);
}

vec3 ground_detail(
	vec3 ground_xz, float steep, float snow, float grass, float warm, float rockish
) {
	float macro = fbm3(ground_xz * macro_scale);
	float patch = fbm2(ground_xz * patch_scale + vec3(macro * 12.0, 0.0, 0.0));
	float clumps = fbm2(ground_xz * (patch_scale * 3.4) + vec3(40.0, 0.0, 11.0));
	float grit = fbm3(ground_xz * grit_scale);

	// Soft cover: lush/dry multipliers, never a hard blob mask.
	vec3 cover = mix(patch_lush, patch_dry, patch);
	cover = mix(cover, vec3(1.05, 1.02, 0.9), clumps * 0.35);
	float cover_w = patch_strength * (1.0 - steep) * (1.0 - snow * 0.85);
	cover_w *= mix(0.55, 1.15, grass * 0.7 + warm * 0.45 + 0.2);

	float macro_w = macro_strength * (1.0 - steep * 0.7);
	float grit_w = grit_strength * mix(0.65, 1.25, warm * 0.8 + rockish * 0.5);
	grit_w *= (1.0 - snow * 0.9) * mix(0.75, 1.25, grass * 0.4 + warm);

	vec3 mul = vec3(1.0);
	mul *= mix(vec3(1.0), cover, cover_w);
	mul *= mix(vec3(1.0), vec3(0.9 + macro * 0.22), macro_w);
	mul *= mix(vec3(1.0), vec3(0.82 + grit * 0.36), grit_w * detail_strength / 0.28);
	return mul;
}

vec3 cliff_detail(vec3 wp, float steep, float rockish) {
	if (steep < 0.01) {
		return vec3(1.0);
	}
	// Bedding / talus streaks follow height so cliffs read as rock faces, not
	// painted ground blotches sliding up the slope.
	float beds = fbm3(vec3(wp.x * 0.08, wp.y * 0.55, wp.z * 0.08));
	float joints = fbm2(vec3(wp.x * 0.35, wp.y * 0.12, wp.z * 0.35) + 19.0);
	float face_grit = fbm2(wp * (grit_scale * 0.65));
	float w = steep * cliff_striation * mix(0.55, 1.0, rockish);
	vec3 rock_mul = vec3(0.78 + beds * 0.28 + joints * 0.1 + face_grit * 0.12);
	return mix(vec3(1.0), rock_mul, w);
}

vec3 bump_offset(vec3 p, float freq, float e) {
	float nx = value_noise((p + vec3(e, 0.0, 0.0)) * freq)
		- value_noise((p - vec3(e, 0.0, 0.0)) * freq);
	float nz = value_noise((p + vec3(0.0, 0.0, e)) * freq)
		- value_noise((p - vec3(0.0, 0.0, e)) * freq);
	return vec3(nx, 0.0, nz);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float snow;
	float grass;
	float warm;
	float rockish;
	surface_masks(COLOR.rgb, snow, grass, warm, rockish);

	float steep = 1.0 - smoothstep(0.32, 0.78, world_normal.y);
	vec3 ground_xz = vec3(world_position.x, 0.0, world_position.z);

	float grain = fbm3(world_position * detail_scale);
	vec3 albedo = COLOR.rgb * (1.0 - detail_strength * 0.45 + detail_strength * grain);

	albedo *= ground_detail(ground_xz, steep, snow, grass, warm, rockish);
	albedo *= cliff_detail(world_position, steep, rockish);

	// Exposed rock: cool and slightly desaturate; keep snow bright.
	vec3 rock_tint = albedo * 0.74 + vec3(0.05, 0.05, 0.055);
	albedo = mix(albedo, rock_tint, steep * 0.7 * (1.0 - snow));
	albedo = mix(albedo, min(albedo * vec3(1.02, 1.03, 1.05), vec3(1.0)), snow * 0.25);

	if (debug_view == 0) {
		ALBEDO = albedo;
		EMISSION = vec3(0.0);
		float rough = 0.93;
		rough -= steep * 0.14;
		rough -= snow * 0.22;
		rough -= warm * 0.04;
		rough += grass * 0.03;
		ROUGHNESS = clamp(rough, 0.35, 0.98);
		SPECULAR = mix(0.12, 0.28, snow);

		// Multi-scale shading normal. Terrain has no tangents, so perturb in
		// world space and rotate into view by hand.
		float flat_amt = bump_strength * (1.0 - steep * 0.55);
		float cliff_amt = cliff_bump_strength * steep;
		vec3 bump = bump_offset(world_position, detail_scale * 1.6, 0.55) * flat_amt;
		bump += bump_offset(world_position, grit_scale * 0.9, 0.18) * (flat_amt * 0.55 + cliff_amt * 0.35);
		bump += bump_offset(
			vec3(world_position.x, world_position.y * 1.8, world_position.z),
			0.22,
			0.9
		) * cliff_amt;
		vec3 perturbed = normalize(world_normal - bump);
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	} else {
		vec3 value = COLOR.rgb;
		if (debug_view == 2) {
			value = world_normal * 0.5 + 0.5;
		} else if (debug_view == 3) {
			value = mix(vec3(0.9, 0.1, 0.1), vec3(0.1, 0.85, 0.2), UV.x);
		}
		ALBEDO = vec3(0.0);
		EMISSION = value;
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	}
}
