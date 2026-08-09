shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Terrain colour is authored per vertex during meshing (biome, slope, snow,
// river mud). This shader only breaks up the flatness that low-poly vertex
// colour would otherwise have, so no textures are needed to read as ground.

uniform float detail_strength : hint_range(0.0, 0.6) = 0.16;
uniform float detail_scale = 0.32;
// Ground is never one colour over a hundred metres. These patches are what
// stop a plain from reading as a painted plane.
uniform float patch_scale = 0.006;
uniform float patch_strength : hint_range(0.0, 1.0) = 0.30;
uniform vec3 patch_dry : source_color = vec3(1.12, 1.05, 0.84);
uniform vec3 patch_lush : source_color = vec3(0.87, 0.96, 0.86);
// Shading bumps only; the mesh stays smooth, but the light stops sliding across
// it as if it were polished.
uniform float bump_strength : hint_range(0.0, 1.0) = 0.09;
// 0 shades normally. 1 shows raw vertex colour unlit, 2 shows the surface
// normal, 3 shows the corridor mask in UV.x (red where 3D relief is suppressed
// for the drainage-surface contract, green where it is free). The unlit views
// are how a suspicious screenshot gets diagnosed.
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

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float grain = value_noise(world_position * detail_scale) * 0.62
		+ value_noise(world_position * detail_scale * 4.3) * 0.38;

	vec3 albedo = COLOR.rgb * (1.0 - detail_strength * 0.5 + detail_strength * grain);

	// Patches lie on the ground, so they are sampled on the ground plane. Using
	// the full position makes them drift with height and read as blotches
	// painted over a hillside rather than as ground cover.
	vec3 ground_position = vec3(world_position.x, 0.0, world_position.z);
	// One broad octave only, and no contrast curve on it. A second octave with a
	// smoothstep over it turns ground cover into camouflage: hard-edged blobs at
	// a fixed size, which the eye reads as a texture bug rather than as terrain.
	float patch = value_noise(ground_position * patch_scale);
	albedo = mix(
		albedo, albedo * mix(patch_lush, patch_dry, patch), patch_strength
	);

	// Steep faces lose their ground tint and read as exposed rock. The edges
	// must ascend: smoothstep with edge0 > edge1 is undefined in GLSL and comes
	// back as NaN on some drivers, which renders the whole surface black.
	float steep = 1.0 - smoothstep(0.32, 0.78, world_normal.y);
	albedo = mix(albedo, albedo * 0.78 + vec3(0.06, 0.06, 0.065), steep * 0.65);

	if (debug_view == 0) {
		ALBEDO = albedo;
		EMISSION = vec3(0.0);
		ROUGHNESS = 0.94 - steep * 0.16;
		SPECULAR = 0.14;
		// Perturb the shading normal in world space and rotate it into view
		// space by hand: the terrain mesh carries no tangents, so NORMAL_MAP
		// has no frame to work in.
		float bump_freq = detail_scale * 1.7;
		float e = 0.6;
		vec3 bump = vec3(
			value_noise((world_position + vec3(e, 0.0, 0.0)) * bump_freq)
				- value_noise((world_position - vec3(e, 0.0, 0.0)) * bump_freq),
			0.0,
			value_noise((world_position + vec3(0.0, 0.0, e)) * bump_freq)
				- value_noise((world_position - vec3(0.0, 0.0, e)) * bump_freq)
		);
		vec3 perturbed = normalize(world_normal - bump * bump_strength);
		NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
	} else {
		// Debug views carry data rather than colour, so they bypass albedo and
		// lighting. Fog is switched off on the environment instead of through
		// the FOG built-in: assigning FOG in only one branch leaves the engine's
		// fog term undefined in the other, which comes back as zero light.
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
