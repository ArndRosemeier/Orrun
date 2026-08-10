//! Bulk continental macro-window fill — matches `ContinentalTerrain.fill_window`.

use godot::prelude::*;

use crate::fields;
use crate::noise::Noise2D;

const SHORE_OUTER: f32 = 0.26;
const COAST_WOBBLE: f32 = 0.20;
const SHELF_DEPTH: f32 = 70.0;
const FREEBOARD_SPAN: f32 = 26.0;
const BIN_DIVISIONS: i32 = 16;
const RIVER_STRIDE: usize = 9;

pub struct FillParams {
	pub origin_x: i32,
	pub origin_z: i32,
	pub cells: i32,
	pub macro_cell_size: f32,
	pub atlas_size: i32,
	pub continent_span: f32,
	pub max_valley_radius: f32,
	pub trunk_valley_radius: f32,
	pub trunk_valley_per_class: f32,
	pub trunk_bank_rise: f32,
	pub swell_height: f32,
	pub mountain_detail: f32,
	pub mountain_octaves: i32,
	pub mountain_gain: f32,
	pub mountain_sharpness: f32,
	pub mountain_macro_contrast: f32,
	pub warp_strength: f32,
	pub ocean_floor_margin: f32,
	pub inland_freeboard: f32,
	pub sea_surface_z: f32,
	pub relief_amp_plains: f32,
	pub relief_amp_hills: f32,
	pub relief_amp_mountains: f32,
	pub seed_swell: i32,
	pub seed_mountain: i32,
	pub seed_warp_a: i32,
	pub seed_warp_b: i32,
	pub seed_moisture: i32,
	pub seed_temperature: i32,
	pub seed_coast: i32,
	pub swell_scale: f32,
	pub mountain_noise_scale: f32,
	pub warp_scale: f32,
	pub settlement_pads: PackedFloat32Array,
	pub settlement_detail_damp: f32,
	pub settlement_core_end: f32,
	pub settlement_pad_stride: i32,
}

fn clamp_octaves(n: i32) -> i32 {
	n.clamp(1, 6)
}

pub fn fill_window(
	elevation_m: PackedFloat32Array,
	humidity01: PackedFloat32Array,
	relief01: PackedFloat32Array,
	water_flag: PackedFloat32Array,
	water_plane: PackedFloat32Array,
	rivers: PackedFloat32Array,
	river_bases: PackedInt32Array,
	p: FillParams,
) -> Dictionary<Variant, Variant> {
	let cells = p.cells as usize;
	let count = cells * cells;
	let cs = p.macro_cell_size;
	let origin = (p.origin_x as f32 * cs, p.origin_z as f32 * cs);
	let span = cells as f32 * cs;
	let radius = p.max_valley_radius;

	let swell = Noise2D::from_period_fbm(p.seed_swell, p.swell_scale, 3, 0.48, 2.1);
	let mountain = Noise2D::from_period_ridged(
		p.seed_mountain,
		p.mountain_noise_scale,
		clamp_octaves(p.mountain_octaves),
		p.mountain_gain,
		2.05,
	);
	let warp_a = Noise2D::from_period_fbm(p.seed_warp_a, p.warp_scale, 3, 0.5, 2.0);
	let warp_b = Noise2D::from_period_fbm(p.seed_warp_b, p.warp_scale, 3, 0.5, 2.0);
	let moisture_n = Noise2D::from_period_fbm(p.seed_moisture, 2100.0, 3, 0.5, 2.0);
	let temperature_n = Noise2D::from_period_fbm(p.seed_temperature, 4200.0, 2, 0.5, 2.0);
	let coast = Noise2D::from_period_fbm(p.seed_coast, 340.0, 4, 0.55, 2.15);

	let bins = bin_rivers(&rivers, &river_bases, origin, span, radius);

	let mut elevation = vec![0.0f32; count];
	let mut relief_amp = vec![0.0f32; count];
	let mut moisture = vec![0.0f32; count];
	let mut temperature = vec![0.0f32; count];

	for cz in 0..cells {
		let wz = (p.origin_z as f32 + cz as f32 + 0.5) * cs;
		let bz = (((wz - origin.1) / span * BIN_DIVISIONS as f32) as i32).clamp(0, BIN_DIVISIONS - 1);
		for cx in 0..cells {
			let wx = (p.origin_x as f32 + cx as f32 + 0.5) * cs;
			let bx = (((wx - origin.0) / span * BIN_DIVISIONS as f32) as i32).clamp(0, BIN_DIVISIONS - 1);
			let index = cz * cells + cx;
			let bin = &bins[(bz * BIN_DIVISIONS + bx) as usize];

			let detail_scale = settlement_detail_scale(
				wx,
				wz,
				&p.settlement_pads,
				p.settlement_pad_stride,
				p.settlement_core_end,
				p.settlement_detail_damp,
			);
			let mut height = base_height(
				wx,
				wz,
				&elevation_m,
				&relief01,
				&water_flag,
				p.atlas_size,
				&warp_a,
				&warp_b,
				&swell,
				&mountain,
				p.warp_strength,
				p.swell_height,
				p.mountain_detail,
				p.mountain_sharpness,
				p.mountain_macro_contrast,
				detail_scale,
			);
			height = carve_valleys(
				height,
				wx,
				wz,
				bin,
				&rivers,
				&relief01,
				p.atlas_size,
				p.trunk_valley_radius,
				p.trunk_valley_per_class,
				p.trunk_bank_rise,
				p.mountain_detail,
				p.swell_height,
				p.mountain_macro_contrast,
				p.sea_surface_z,
				detail_scale,
			);
			height = shore_authority(
				height,
				wx,
				wz,
				&water_flag,
				&water_plane,
				p.atlas_size,
				&coast,
				p.ocean_floor_margin,
				p.inland_freeboard,
				p.sea_surface_z,
			);

			elevation[index] = height;
			let rel = fields::sample_smooth(&relief01, p.atlas_size, wx, wz);
			relief_amp[index] = relief_amp_of(
				rel,
				p.relief_amp_plains,
				p.relief_amp_hills,
				p.relief_amp_mountains,
			) * detail_scale;
			moisture[index] = moisture_of(wx, wz, &humidity01, p.atlas_size, &moisture_n);
			temperature[index] =
				temperature_for(wx, wz, height, p.continent_span, &temperature_n);
		}
	}

	let elev_arr = PackedFloat32Array::from(elevation);
	let rel_arr = PackedFloat32Array::from(relief_amp);
	let moist_arr = PackedFloat32Array::from(moisture);
	let temp_arr = PackedFloat32Array::from(temperature);
	let mut out = Dictionary::<Variant, Variant>::new();
	out.set("elevation", &elev_arr);
	out.set("relief_amp", &rel_arr);
	out.set("moisture", &moist_arr);
	out.set("temperature", &temp_arr);
	out
}

fn bin_rivers(
	rivers: &PackedFloat32Array,
	bases: &PackedInt32Array,
	origin: (f32, f32),
	span: f32,
	radius: f32,
) -> Vec<Vec<i32>> {
	let mut bins = vec![Vec::<i32>::new(); (BIN_DIVISIONS * BIN_DIVISIONS) as usize];
	let bin_span = span / BIN_DIVISIONS as f32;
	for i in 0..bases.len() {
		let base = bases[i] as usize;
		if base + 5 >= rivers.len() {
			continue;
		}
		let min_x = rivers[base].min(rivers[base + 3]) - radius;
		let max_x = rivers[base].max(rivers[base + 3]) + radius;
		let min_z = rivers[base + 2].min(rivers[base + 5]) - radius;
		let max_z = rivers[base + 2].max(rivers[base + 5]) + radius;
		if max_x < origin.0 || max_z < origin.1 {
			continue;
		}
		let x0 = (((min_x - origin.0) / bin_span).floor() as i32).clamp(0, BIN_DIVISIONS - 1);
		let x1 = (((max_x - origin.0) / bin_span).floor() as i32).clamp(0, BIN_DIVISIONS - 1);
		let z0 = (((min_z - origin.1) / bin_span).floor() as i32).clamp(0, BIN_DIVISIONS - 1);
		let z1 = (((max_z - origin.1) / bin_span).floor() as i32).clamp(0, BIN_DIVISIONS - 1);
		for bz in z0..=z1 {
			for bx in x0..=x1 {
				bins[(bz * BIN_DIVISIONS + bx) as usize].push(bases[i]);
			}
		}
	}
	bins
}

fn settlement_detail_scale(
	world_x: f32,
	world_z: f32,
	pads: &PackedFloat32Array,
	stride: i32,
	core_end: f32,
	detail_damp: f32,
) -> f32 {
	let stride = stride.max(3) as usize;
	let mut best = 0.0f32;
	let mut i = 0usize;
	while i + stride <= pads.len() {
		let cx = pads[i];
		let cz = pads[i + 1];
		let radius = pads[i + 2];
		i += stride;
		if radius <= 1.0 {
			continue;
		}
		let dx = world_x - cx;
		let dz = world_z - cz;
		let d = (dx * dx + dz * dz).sqrt() / radius;
		if d >= 1.0 {
			continue;
		}
		let w = 1.0 - smoothstep(core_end, 1.0, d);
		if w > best {
			best = w;
		}
	}
	1.0 - best * detail_damp
}

fn base_height(
	world_x: f32,
	world_z: f32,
	elevation_m: &PackedFloat32Array,
	relief01: &PackedFloat32Array,
	water_flag: &PackedFloat32Array,
	atlas_size: i32,
	warp_a: &Noise2D,
	warp_b: &Noise2D,
	swell: &Noise2D,
	mountain: &Noise2D,
	warp_strength: f32,
	swell_height: f32,
	mountain_detail: f32,
	mountain_sharpness: f32,
	mountain_macro_contrast: f32,
	detail_scale: f32,
) -> f32 {
	let warp_x = warp_a.get(world_x, world_z) * warp_strength;
	let warp_z = warp_b.get(world_x, world_z) * warp_strength;
	let px = world_x + warp_x;
	let pz = world_z + warp_z;

	let relief = fields::sample_smooth(relief01, atlas_size, world_x, world_z);
	let base = atlas_base_steepened(
		elevation_m,
		atlas_size,
		world_x,
		world_z,
		relief,
		mountain_macro_contrast,
	);
	let wet = fields::sample_smooth(water_flag, atlas_size, world_x, world_z).clamp(0.0, 1.0);
	let dryness = lerp(0.18, 1.0, 1.0 - wet);

	let swell_v = swell.get(px, pz) * swell_height * lerp(1.0, 0.4, relief);
	let ridge01 = (mountain.get(px * 0.9, pz * 0.9) * 0.5 + 0.5).clamp(0.0, 1.0);
	let shaped = ridge01.powf(mountain_sharpness.max(0.5));
	let ridge = (shaped - 0.35) * mountain_detail * lerp(0.35, 1.0, relief);
	base + (swell_v + ridge) * dryness * detail_scale
}

fn atlas_base_steepened(
	elevation_m: &PackedFloat32Array,
	atlas_size: i32,
	world_x: f32,
	world_z: f32,
	relief: f32,
	contrast: f32,
) -> f32 {
	let e0 = fields::sample_smooth(elevation_m, atlas_size, world_x, world_z);
	if contrast <= 1.001 || relief < 0.04 {
		return e0;
	}
	let r = 1400.0;
	let e_avg = (
		fields::sample_smooth(elevation_m, atlas_size, world_x - r, world_z)
			+ fields::sample_smooth(elevation_m, atlas_size, world_x + r, world_z)
			+ fields::sample_smooth(elevation_m, atlas_size, world_x, world_z - r)
			+ fields::sample_smooth(elevation_m, atlas_size, world_x, world_z + r)
	) * 0.25;
	let amount = lerp(1.0, contrast, relief.clamp(0.0, 1.0));
	e_avg + (e0 - e_avg) * amount
}

fn carve_valleys(
	height: f32,
	world_x: f32,
	world_z: f32,
	bases: &[i32],
	rivers: &PackedFloat32Array,
	relief01: &PackedFloat32Array,
	atlas_size: i32,
	trunk_valley_radius: f32,
	trunk_valley_per_class: f32,
	trunk_bank_rise: f32,
	mountain_detail: f32,
	swell_height: f32,
	mountain_macro_contrast: f32,
	sea_surface_z: f32,
	detail_scale: f32,
) -> f32 {
	let mut out = height;
	let relief = fields::sample_smooth(relief01, atlas_size, world_x, world_z);
	let contrast_gutter = ((mountain_macro_contrast - 1.0).max(0.0) * 18.0 * relief).min(22.0);
	let detail_amp = (mountain_detail * lerp(0.35, 1.0, relief) * 0.65
		+ swell_height * lerp(1.0, 0.4, relief) * 0.35
		+ contrast_gutter)
		* detail_scale;
	let min_gutter = trunk_bank_rise + detail_amp;
	for &base_i in bases {
		let base = base_i as usize;
		if base + 8 >= rivers.len() {
			continue;
		}
		let ax = rivers[base];
		let ay = rivers[base + 1];
		let az = rivers[base + 2];
		let bx = rivers[base + 3];
		let by = rivers[base + 4];
		let bz = rivers[base + 5];
		let feature_class = rivers[base + 8] as i32;
		let radius = trunk_valley_radius
			+ trunk_valley_per_class * (feature_class.clamp(1, 4) - 1) as f32;

		let t = segment_param(world_x, world_z, ax, az, bx, bz);
		let px = ax + (bx - ax) * t;
		let pz = az + (bz - az) * t;
		let d = ((world_x - px) * (world_x - px) + (world_z - pz) * (world_z - pz)).sqrt();
		if d >= radius {
			continue;
		}
		let atlas_floor = ay + (by - ay) * t + trunk_bank_rise;
		// Match GDScript: never dig dry land below global sea.
		let floor_z = atlas_floor
			.min(height - min_gutter)
			.min(height)
			.max(sea_surface_z);
		let ramp = smoothstep(0.0, radius, d);
		out = out.min(lerp(floor_z, height, ramp));
	}
	let _ = RIVER_STRIDE;
	out
}

fn shore_authority(
	height: f32,
	world_x: f32,
	world_z: f32,
	water_flag: &PackedFloat32Array,
	water_plane: &PackedFloat32Array,
	atlas_size: i32,
	coast: &Noise2D,
	ocean_floor_margin: f32,
	inland_freeboard: f32,
	sea_surface_z: f32,
) -> f32 {
	let wet = fields::sample_smooth(water_flag, atlas_size, world_x, world_z);
	let wobble = coast.get(world_x, world_z) * COAST_WOBBLE;
	let signed_shore = 0.5 - wet + wobble;
	let plane = fields::sample_linear(water_plane, atlas_size, world_x, world_z);

	if signed_shore <= 0.0 {
		let wetness = smoothstep(0.0, SHORE_OUTER, -signed_shore);
		let depth = (ocean_floor_margin + SHELF_DEPTH * wetness) * wetness;
		return height.min(plane - depth);
	}
	// Absolute floor: dry ground stays at or above the global sea.
	let height = height.max(sea_surface_z);
	let band = 1.0 - smoothstep(0.0, SHORE_OUTER, signed_shore);
	if band <= 0.0 {
		return height;
	}
	let dryness = smoothstep(0.0, SHORE_OUTER, signed_shore);
	let freeboard = (inland_freeboard + FREEBOARD_SPAN * dryness) * dryness;
	lerp(height, height.max(plane + freeboard), band)
}

fn relief_amp_of(relief01: f32, plains: f32, hills: f32, mountains: f32) -> f32 {
	let amp = lerp(plains, hills, smoothstep(0.12, 0.55, relief01));
	lerp(amp, mountains, smoothstep(0.55, 0.92, relief01))
}

fn moisture_of(
	world_x: f32,
	world_z: f32,
	humidity01: &PackedFloat32Array,
	atlas_size: i32,
	moisture_n: &Noise2D,
) -> f32 {
	let atlas_humidity = fields::sample_smooth(humidity01, atlas_size, world_x, world_z);
	let local = moisture_n.get(world_x, world_z) * 0.5 + 0.5;
	(atlas_humidity * 0.75 + local * 0.25).clamp(0.0, 1.0)
}

fn temperature_for(
	world_x: f32,
	world_z: f32,
	height: f32,
	continent_span: f32,
	temperature_n: &Noise2D,
) -> f32 {
	let latitude = (world_z / continent_span).clamp(0.0, 1.0);
	let alpine = smoothstep(420.0, 900.0, height);
	(0.28 + latitude * 0.46 + temperature_n.get(world_x, world_z) * 0.16 - alpine * 0.42)
		.clamp(0.0, 1.0)
}

#[inline]
fn segment_param(px: f32, pz: f32, ax: f32, az: f32, bx: f32, bz: f32) -> f32 {
	let dx = bx - ax;
	let dz = bz - az;
	let len_sq = dx * dx + dz * dz;
	if len_sq < 0.000001 {
		return 0.0;
	}
	(((px - ax) * dx + (pz - az) * dz) / len_sq).clamp(0.0, 1.0)
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
	a + (b - a) * t
}

#[inline]
fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
	let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
	t * t * (3.0 - 2.0 * t)
}
