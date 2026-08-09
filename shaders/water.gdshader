shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, diffuse_burley;

// One material for rivers and lakes. Depth is read from the scene rather than
// assumed, so the same shader works for a shallow ford and a deep tarn, and the
// shoreline foam follows wherever the ground actually meets the surface.

uniform vec3 shallow_color : source_color = vec3(0.24, 0.42, 0.40);
uniform vec3 deep_color : source_color = vec3(0.04, 0.11, 0.17);
uniform float depth_fade = 2.2;
// Foam is a shoreline effect, not a shallow-water effect. A wide value turns
// every gently shelving lake margin into a white pan.
uniform float foam_width = 0.28;
// Metres of depth over which the sheet fades in from nothing at the shore.
// Kept below typical channel depth so a ford still softens, but a normal bed
// (a metre or more) stays fully opaque.
uniform float shore_fade = 0.35;
uniform float ripple_scale = 1.4;
uniform float ripple_speed = 0.35;
uniform float flow_speed = 0.55;
uniform sampler2D depth_buffer : hint_depth_texture, filter_linear_mipmap;

varying vec3 world_position;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Bed clearance authored into UV.y by WaterSurface. Scene depth is only a
	// fallback: LOD skirts, bank triangles and chunk seams routinely put opaque
	// geometry near the sheet in the depth buffer, which made water_depth go to
	// zero and whole stretches of river vanish while the trench stayed green.
	float authored_depth = UV.y;
	float raw = texture(depth_buffer, SCREEN_UV).x;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	view.xyz /= view.w;
	float floor_distance = -view.z;
	float surface_distance = -VERTEX.z;
	float scene_depth = max(floor_distance - surface_distance, 0.0);
	float water_depth = max(authored_depth, scene_depth);

	float t = TIME;
	vec2 drift = vec2(0.0, t * flow_speed);
	float ripple = value_noise(world_position.xz * ripple_scale + drift)
		+ value_noise(world_position.zx * ripple_scale * 2.7 - drift * 1.3) * 0.5;
	ripple = (ripple / 1.5 - 0.5) * 2.0;

	vec3 tint = mix(shallow_color, deep_color, clamp(water_depth / depth_fade, 0.0, 1.0));

	// The sheet is built on a voxel grid, so its outer rim is a staircase. Fading
	// it out over the last few centimetres of depth hands the shoreline back to
	// the terrain: what you see is where the ground crosses the water, which is
	// a smooth curve, instead of where the mesher happened to stop.
	float shore = smoothstep(0.0, shore_fade, water_depth);
	float foam = (1.0 - smoothstep(0.06, foam_width + shore_fade, water_depth)) * shore;

	ALBEDO = mix(tint, vec3(0.82, 0.86, 0.86), foam * 0.4);
	ALPHA = clamp(0.44 + water_depth * 0.2, 0.0, 0.94) * shore;
	ROUGHNESS = mix(0.06, 0.35, foam);
	METALLIC = 0.0;
	SPECULAR = 0.6;
	NORMAL_MAP = vec3(
		0.5 + ripple * 0.06 * sin(t * ripple_speed),
		0.5 + ripple * 0.06 * cos(t * ripple_speed * 0.8),
		1.0
	);
	NORMAL_MAP_DEPTH = 0.6;
}
