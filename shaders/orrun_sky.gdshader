shader_type sky;
render_mode use_half_res_pass;
/// Orrun title-art sky: cool zenith, warm sun horizon, layered soft-volume
/// clouds with silver lining and a storm shelf. Half-res cloud pass; cheaper
/// cubemap for IBL. Not meant for flying through — ground view only.

group_uniforms Atmosphere;
uniform vec3 zenith_color : source_color = vec3(0.18, 0.28, 0.48);
uniform vec3 zenith_storm_color : source_color = vec3(0.10, 0.14, 0.22);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.70, 0.78);
uniform vec3 sun_horizon_color : source_color = vec3(1.0, 0.62, 0.32);
uniform float horizon_blend = 0.22;
uniform float sun_horizon_strength = 0.85;

group_uniforms SunDisk;
uniform float sun_disk_size = 0.012;
uniform float sun_glow_size = 0.22;
uniform float sun_glow_intensity = 1.35;
uniform float sun_disk_intensity = 8.0;

group_uniforms Clouds;
uniform float cloud_coverage = 0.52;
uniform float cloud_softness = 0.14;
uniform float cloud_scale = 1.85;
uniform float cloud_detail_scale = 3.6;
uniform float cloud_speed = 0.008;
uniform float cloud_height_bias = 0.12;
uniform float cloud_horizon_fade = 0.08;
uniform float domain_warp = 0.35;
uniform float storm_amount = 0.62;
uniform float storm_sharpness = 1.35;
uniform vec3 cloud_lit_color : source_color = vec3(0.95, 0.93, 0.90);
uniform vec3 cloud_shade_color : source_color = vec3(0.22, 0.26, 0.34);
uniform vec3 cloud_storm_color : source_color = vec3(0.08, 0.10, 0.14);
uniform vec3 cloud_rim_color : source_color = vec3(1.0, 0.88, 0.55);
uniform float rim_power = 3.2;
uniform float rim_intensity = 1.55;
uniform float ambient_sky_lift = 0.18;

group_uniforms Quality;
/// Octaves for the visible half-res cloud pass.
uniform int cloud_octaves : hint_range(3, 7) = 5;
/// Octaves when baking the radiance cubemap (IBL).
uniform int cubemap_octaves : hint_range(2, 5) = 3;


float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int i = 0; i < 7; i++) {
		if (i >= octaves) {
			break;
		}
		sum += value_noise(p) * amp;
		norm += amp;
		p = p * 2.02 + vec2(17.1, 9.3);
		amp *= 0.5;
	}
	return sum / max(norm, 0.0001);
}

vec3 sun_direction() {
	if (LIGHT0_ENABLED) {
		// Sky sun sits where the directional light *comes from*.
		return normalize(-LIGHT0_DIRECTION);
	}
	return normalize(vec3(0.42, 0.58, 0.35));
}

vec3 atmosphere(vec3 dir, vec3 sun_dir) {
	float elev = asin(clamp(dir.y, -1.0, 1.0));
	float h = 1.0 - smoothstep(0.0, horizon_blend * PI * 0.5, max(elev, 0.0));
	h = pow(h, 1.15);

	float sun_az = max(dot(normalize(vec3(dir.x, 0.0, dir.z)), normalize(vec3(sun_dir.x, 0.0, sun_dir.z))), 0.0);
	float sun_side = pow(sun_az, 2.5) * smoothstep(0.05, 0.55, sun_dir.y);
	float toward_sun = pow(max(dot(dir, sun_dir), 0.0), 8.0);

	vec3 storm_zenith = mix(zenith_color, zenith_storm_color, storm_amount * 0.65);
	vec3 sky = mix(storm_zenith, horizon_color, h);
	sky = mix(sky, sun_horizon_color, h * sun_horizon_strength * (0.35 + 0.65 * sun_side));
	sky += sun_horizon_color * toward_sun * 0.22 * sun_side;
	return sky;
}

float cloud_density(vec3 dir, float t, int octaves) {
	// Project onto a soft sky dome so clouds sit above the horizon.
	float elev = max(dir.y, 0.0);
	float dome = elev / max(0.08 + elev, 0.0001);
	vec2 uv = dir.xz / max(dome, 0.001);
	uv *= cloud_scale;
	uv += vec2(t * cloud_speed * 1.7, t * cloud_speed);

	vec2 warp = vec2(
		fbm(uv * 0.7 + vec2(0.0, 4.2), min(octaves, 4)),
		fbm(uv * 0.7 + vec2(9.1, 1.3), min(octaves, 4))
	);
	uv += (warp - 0.5) * domain_warp;

	float base = fbm(uv, octaves);
	float detail = fbm(uv * cloud_detail_scale + vec2(t * cloud_speed * 0.4, -t * cloud_speed * 0.25), max(octaves - 1, 2));
	float n = base * 0.72 + detail * 0.28;

	// Storm shelf: heavier, darker bank opposite the brighter sun side.
	vec3 sun_dir = sun_direction();
	float away = 1.0 - max(dot(normalize(vec3(dir.x, 0.0, dir.z)), normalize(vec3(sun_dir.x, 0.0, sun_dir.z))), 0.0);
	float shelf = smoothstep(0.25, 0.95, away) * storm_amount;
	float coverage = mix(cloud_coverage, cloud_coverage + 0.22, shelf);
	coverage = clamp(coverage + cloud_height_bias * (1.0 - elev), 0.05, 0.95);

	float d = smoothstep(coverage, coverage + cloud_softness, n);
	d = pow(d, mix(1.0, storm_sharpness, shelf));
	d *= smoothstep(cloud_horizon_fade, cloud_horizon_fade + 0.18, elev);
	d *= mix(1.0, 1.25, shelf);
	return clamp(d, 0.0, 1.0);
}

vec3 cloud_normal(vec3 dir, float t, int octaves, float dens) {
	// Finite differences on the sphere for soft volume lighting.
	float eps = 0.012;
	vec3 tx = normalize(cross(vec3(0.0, 1.0, 0.0), dir));
	if (length(tx) < 0.001) {
		tx = vec3(1.0, 0.0, 0.0);
	}
	vec3 ty = normalize(cross(dir, tx));
	float dx = cloud_density(normalize(dir + tx * eps), t, octaves) - dens;
	float dy = cloud_density(normalize(dir + ty * eps), t, octaves) - dens;
	// Density increases "into" the cloud; invert so lit faces look outward.
	return normalize(vec3(-dx, -dy, max(0.15, 1.0 - dens)));
}

vec4 evaluate_clouds(vec3 dir, float t, int octaves) {
	if (dir.y < cloud_horizon_fade * 0.5) {
		return vec4(0.0);
	}
	float dens = cloud_density(dir, t, octaves);
	if (dens < 0.001) {
		return vec4(0.0);
	}

	vec3 sun_dir = sun_direction();
	vec3 n = cloud_normal(dir, t, max(octaves - 1, 2), dens);
	// Remap tangent-space-ish normal into a cheap lit response along sun.
	float ndl = clamp(0.55 + 0.45 * n.z + 0.35 * dot(n.xy, sun_dir.xz), 0.0, 1.0);
	float powder = pow(1.0 - dens, 2.0);
	float toward_sun = max(dot(dir, sun_dir), 0.0);
	float rim = pow(toward_sun, rim_power) * powder * dens;

	vec3 sun_dir_flat = normalize(vec3(sun_dir.x, 0.0, sun_dir.z));
	float away = 1.0 - max(dot(normalize(vec3(dir.x, 0.0, dir.z)), sun_dir_flat), 0.0);
	float storm = smoothstep(0.3, 0.95, away) * storm_amount * dens;

	vec3 shade = mix(cloud_shade_color, cloud_storm_color, storm);
	vec3 col = mix(shade, cloud_lit_color, ndl);
	col = mix(col, cloud_rim_color, clamp(rim * rim_intensity, 0.0, 1.0));

	vec3 sun_col = LIGHT0_ENABLED ? LIGHT0_COLOR * LIGHT0_ENERGY : vec3(1.0, 0.95, 0.85);
	col *= mix(vec3(1.0), sun_col, 0.25 + 0.35 * ndl);
	col += atmosphere(dir, sun_dir) * ambient_sky_lift * (1.0 - dens * 0.7);

	float alpha = smoothstep(0.02, 0.85, dens);
	alpha = mix(alpha, min(1.0, alpha * 1.15), storm);
	return vec4(col, alpha);
}

vec3 sun_disk(vec3 dir, vec3 sun_dir) {
	float d = acos(clamp(dot(dir, sun_dir), -1.0, 1.0));
	float disk = smoothstep(sun_disk_size, sun_disk_size * 0.35, d);
	float glow = exp(-d / max(sun_glow_size, 0.001));
	vec3 sun_col = LIGHT0_ENABLED ? LIGHT0_COLOR * LIGHT0_ENERGY : vec3(1.0, 0.95, 0.8);
	return sun_col * (disk * sun_disk_intensity + glow * sun_glow_intensity);
}


void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 sun_dir = sun_direction();
	float t = TIME;

	if (AT_HALF_RES_PASS) {
		vec4 clouds = evaluate_clouds(dir, t, cloud_octaves);
		COLOR = clouds.rgb;
		ALPHA = clouds.a;
	} else {
		vec3 sky = atmosphere(dir, sun_dir);
		if (AT_CUBEMAP_PASS) {
			// Cheaper clouds for IBL so radiance updates stay affordable with TIME.
			vec4 clouds = evaluate_clouds(dir, t, cubemap_octaves);
			sky = mix(sky, clouds.rgb, clouds.a * 0.85);
			sky += sun_disk(dir, sun_dir) * 0.35;
			COLOR = sky;
		} else {
			sky += sun_disk(dir, sun_dir);
			vec4 clouds = HALF_RES_COLOR;
			// Slight full-res density tip so half-res blur does not smear edges.
			float tip = cloud_density(dir, t, 3);
			clouds.a = max(clouds.a, tip * tip * 0.25);
			COLOR = mix(sky, clouds.rgb, clamp(clouds.a, 0.0, 1.0));
		}
	}
}
