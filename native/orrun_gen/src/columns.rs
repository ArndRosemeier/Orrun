//! Column density builder — ports `DensityField._build_columns` + post-passes.
//!
//! GDScript pre-samples macro/hydro grids; Rust owns segment scans, carves, and
//! bridge/water seals.

use godot::prelude::*;

use crate::noise::Noise2D;

const TILE_DIVISIONS: i32 = 4;
const BANK_RISE: f32 = 1.1;
const WATER_FREEBOARD: f32 = 0.45;
const MAX_CHORD_BURY: f32 = 1.6;
const CHORD_BREAK_FACTOR: f32 = 2.5;
const MIN_BED_CLEARANCE: f32 = 0.12;
const MIN_VISIBLE_WATER_CLEARANCE: f32 = 0.02;
const ESTUARY_BLEND_METRES: f32 = 220.0;
const COASTAL_BED_MAX_BELOW_PLANE: f32 = 2.2;
const COASTAL_BED_BLEND_METRES: f32 = 440.0;
const BRIDGE_GRADE_STRIDE: usize = 10;
const BRIDGE_CONTACT_RADIUS: f32 = 5.5;
const RIVER_STRIDE: usize = 10;
const ROAD_STRIDE: usize = 8;
/// Finite stand-in for "no water sheet". Godot `PackedFloat32Array` ↔ Rust
/// does not reliably preserve `±INF`, so dry markers must be finite.
const NO_WATER: f32 = -1.0e20;
const NO_WATER_THRESH: f32 = -1.0e19;
/// Finite stand-in for "no wet columns" on `min_water_clearance`.
const NO_CLEARANCE: f32 = 1.0e20;
/// Channel count in the packed `grids` buffer passed across the FFI.
pub const GRID_CHANNELS: usize = 10;

#[inline]
fn has_sheet(z: f32) -> bool {
	z > NO_WATER_THRESH
}

const GRASS_PLAINS: Color = Color::from_rgba(0.36, 0.47, 0.22, 1.0);
const GRASS_FOREST: Color = Color::from_rgba(0.24, 0.38, 0.19, 1.0);
const DRY_BADLANDS: Color = Color::from_rgba(0.49, 0.40, 0.25, 1.0);
const ALPINE_TUNDRA: Color = Color::from_rgba(0.42, 0.44, 0.36, 1.0);

#[inline]
fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
	let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
	t * t * (3.0 - 2.0 * t)
}

#[inline]
fn lerpf(a: f32, b: f32, t: f32) -> f32 {
	a + (b - a) * t
}

#[inline]
fn segment_param(px: f32, pz: f32, ax: f32, az: f32, bx: f32, bz: f32) -> f32 {
	let dx = bx - ax;
	let dz = bz - az;
	let len_sq = dx * dx + dz * dz;
	if len_sq < 1.0e-6 {
		return 0.0;
	}
	(((px - ax) * dx + (pz - az) * dz) / len_sq).clamp(0.0, 1.0)
}

fn classify_biome(moisture: f32, temperature: f32, elevation: f32, relief: f32) -> u8 {
	if elevation > 520.0 || temperature < 0.16 {
		return 3;
	}
	if moisture < 0.36 && relief > 16.0 {
		return 2;
	}
	if moisture > 0.5 && relief > 7.0 {
		return 1;
	}
	0
}

fn relief_scale(biome: u8) -> f32 {
	match biome {
		0 => 0.55,
		1 => 0.9,
		2 => 1.25,
		3 => 1.15,
		_ => 1.0,
	}
}

fn ground_color(moisture: f32, temperature: f32, elevation: f32, relief: f32) -> Color {
	let forest = smoothstep(0.42, 0.60, moisture) * smoothstep(4.0, 12.0, relief);
	let badlands = (1.0 - smoothstep(0.28, 0.44, moisture)) * smoothstep(10.0, 22.0, relief);
	let alpine = smoothstep(380.0, 560.0, elevation)
		.max(1.0 - smoothstep(0.12, 0.32, temperature));
	let mut color = GRASS_PLAINS.lerp(GRASS_FOREST, forest as f64);
	color = color.lerp(DRY_BADLANDS, badlands as f64);
	color.lerp(ALPINE_TUNDRA, alpine as f64)
}

fn relief_value(relief: &Noise2D, fine: &Noise2D, wx: f32, wz: f32, amp: f32, mountain_amp: f32) -> f32 {
	let ridge = relief.get(wx, wz);
	let fine_n = fine.get(wx, wz);
	let fine_w = lerpf(0.08, 0.02, (amp / mountain_amp.max(1.0)).clamp(0.0, 1.0));
	ridge * (1.0 - fine_w) + fine_n * fine_w
}

fn ford_relief(fords: &PackedVector3Array, wx: f32, wz: f32) -> f32 {
	let mut scale = 1.0f32;
	for i in 0..fords.len() {
		let ford = fords[i];
		let d = ((wx - ford.x).powi(2) + (wz - ford.y).powi(2)).sqrt();
		if d < ford.z {
			scale = scale.min(lerpf(0.22, 1.0, smoothstep(0.0, ford.z, d)));
		}
	}
	scale
}

fn axial_bridge_gap(grades: &PackedFloat32Array, wx: f32, wz: f32) -> f32 {
	let mut gap = 0.0f32;
	let count = grades.len() / BRIDGE_GRADE_STRIDE;
	for i in 0..count {
		let base = i * BRIDGE_GRADE_STRIDE;
		let cx = grades[base];
		let cz = grades[base + 1];
		let ax = grades[base + 2];
		let az = grades[base + 3];
		let gap_half = grades[base + 5];
		let half_w = grades[base + 8];
		let dx = wx - cx;
		let dz = wz - cz;
		let along = (dx * ax + dz * az).abs();
		let lateral = (dx * az - dz * ax).abs();
		if lateral > half_w + 4.0 || along > gap_half + 4.0 {
			continue;
		}
		let along_w = 1.0 - smoothstep(gap_half, gap_half + 4.0, along);
		let lat_w = 1.0 - smoothstep(half_w, half_w + 4.0, lateral);
		gap = gap.max(along_w * lat_w);
	}
	gap.clamp(0.0, 1.0)
}

pub struct ColumnParams {
	pub samples_h: i32,
	pub voxel: f32,
	pub origin_x: f32,
	pub origin_z: f32,
	pub tile_span: f32,
	pub corridor_inner: f32,
	pub corridor_outer: f32,
	pub macro_cell_size: f32,
	pub relief_amp_mountains: f32,
	pub relief_amp_plains: f32,
	pub overhang_amount: f32,
	pub seed_relief: i32,
	pub seed_relief_fine: i32,
}

pub fn build_columns(
	grids: PackedFloat32Array,
	rivers: PackedFloat32Array,
	roads: PackedFloat32Array,
	river_tile_starts: PackedInt32Array,
	river_tile_indices: PackedInt32Array,
	road_tile_starts: PackedInt32Array,
	road_tile_indices: PackedInt32Array,
	fords: PackedVector3Array,
	bridge_grades: PackedFloat32Array,
	p: ColumnParams,
) -> Dictionary<Variant, Variant> {
	let samples_h = p.samples_h as usize;
	let count = samples_h * samples_h;
	let grids = grids.as_slice();
	assert_eq!(grids.len(), count * GRID_CHANNELS, "grids len");
	assert_eq!(river_tile_starts.len(), (TILE_DIVISIONS * TILE_DIVISIONS + 1) as usize);
	assert_eq!(road_tile_starts.len(), (TILE_DIVISIONS * TILE_DIVISIONS + 1) as usize);
	#[inline]
	fn ch(grids: &[f32], count: usize, channel: usize, index: usize) -> f32 {
		grids[channel * count + index]
	}

	let relief_n = Noise2D::from_period_ridged(p.seed_relief, 480.0, 3, 0.45, 2.1);
	let fine_n = Noise2D::from_period_fbm(p.seed_relief_fine, 95.0, 2, 0.45, 2.0);

	let mut surface_z = vec![0.0f32; count];
	let mut corridor_mask = vec![0.0f32; count];
	let mut wetness = vec![0.0f32; count];
	let mut roadness = vec![0.0f32; count];
	let mut biome = vec![0u8; count];
	let mut temperature_out = vec![0.0f32; count];
	let mut ground_color_out = vec![Color::from_rgba(0.0, 0.0, 0.0, 1.0); count];
	let mut overhang_amp = vec![0.0f32; count];
	let mut contract_error = vec![0.0f32; count];
	let mut water_top = vec![NO_WATER; count];
	let mut river_dist = vec![f32::INFINITY; count];
	let mut wet_half_of = vec![0.0f32; count];

	let mut has_water = false;
	let mut wet_columns = 0i32;
	let mut wet_columns_failing = 0i32;
	let mut min_water_clearance = NO_CLEARANCE;
	let mut worst_error = 0.0f32;

	for iz in 0..samples_h {
		let wz = p.origin_z + iz as f32 * p.voxel;
		let tile_z = ((wz - p.origin_z) / p.tile_span).floor() as i32;
		let tile_z = tile_z.clamp(0, TILE_DIVISIONS - 1);
		for ix in 0..samples_h {
			let wx = p.origin_x + ix as f32 * p.voxel;
			let tile_x = ((wx - p.origin_x) / p.tile_span).floor() as i32;
			let tile_x = tile_x.clamp(0, TILE_DIVISIONS - 1);
			let tile = (tile_z * TILE_DIVISIONS + tile_x) as usize;
			let index = iz * samples_h + ix;

			let h = ch(grids, count, 0, index);
			if !(h.is_finite() && h > NO_WATER_THRESH) {
				panic!("build_columns height[{index}] is not land height ({h})");
			}
			let mut amp = ch(grids, count, 1, index);
			let moist = ch(grids, count, 2, index);
			let temp = ch(grids, count, 3, index);
			let biome_id = classify_biome(moist, temp, h, amp);
			let tint = ground_color(moist, temp, h, amp);
			amp *= relief_scale(biome_id);

			let mut river_d = f32::INFINITY;
			let mut river_edge_d = f32::INFINITY;
			let mut river_water_z = NO_WATER;
			let mut river_depth = 0.0f32;
			let mut river_valley = 1.0f32;
			let mut river_half = 0.0f32;
			let r_start = river_tile_starts[tile] as usize;
			let r_end = river_tile_starts[tile + 1] as usize;
			for ti in r_start..r_end {
				let base = river_tile_indices[ti] as usize;
				let ax = rivers[base];
				let ay = rivers[base + 1];
				let az = rivers[base + 2];
				let bx = rivers[base + 3];
				let by = rivers[base + 4];
				let bz = rivers[base + 5];
				let t = segment_param(wx, wz, ax, az, bx, bz);
				let px = ax + (bx - ax) * t;
				let pz = az + (bz - az) * t;
				let d = ((wx - px).powi(2) + (wz - pz).powi(2)).sqrt();
				if d >= river_d {
					continue;
				}
				river_d = d;
				river_half = lerpf(rivers[base + 6], rivers[base + 7], t);
				river_water_z = ay + (by - ay) * t;
				river_depth = rivers[base + 8];
				river_valley = rivers[base + 9];
				river_edge_d = d - river_half;
			}

			let mut road_d = f32::INFINITY;
			let mut road_edge_d = f32::INFINITY;
			let mut road_z = 0.0f32;
			let mut road_half = 0.0f32;
			let rd_start = road_tile_starts[tile] as usize;
			let rd_end = road_tile_starts[tile + 1] as usize;
			for ti in rd_start..rd_end {
				let base = road_tile_indices[ti] as usize;
				let ax = roads[base];
				let ay = roads[base + 1];
				let az = roads[base + 2];
				let bx = roads[base + 3];
				let by = roads[base + 4];
				let bz = roads[base + 5];
				let t = segment_param(wx, wz, ax, az, bx, bz);
				let px = ax + (bx - ax) * t;
				let pz = az + (bz - az) * t;
				let d = ((wx - px).powi(2) + (wz - pz).powi(2)).sqrt();
				if d >= road_d {
					continue;
				}
				road_d = d;
				road_half = roads[base + 6];
				road_z = ay + (by - ay) * t;
				road_edge_d = d - road_half;
			}

			let lake_edge = ch(grids, count, 6, index);
			let lake_surf = coerce_sheet(ch(grids, count, 7, index));
			let shore = ch(grids, count, 4, index);
			let atlas = ch(grids, count, 5, index);
			let atlas_surface = if shore <= 0.0 {
				coerce_sheet(atlas)
			} else {
				NO_WATER
			};

			let mut nearest_wet = river_edge_d.min(lake_edge);
			nearest_wet = nearest_wet.min(shore.max(0.0));
			let nearest_feature = nearest_wet.min(road_edge_d);
			let mask = smoothstep(p.corridor_inner, p.corridor_outer, nearest_feature);

			let relief = relief_value(&relief_n, &fine_n, wx, wz, amp, p.relief_amp_mountains);
			let mut surface = h + relief * amp * mask;

			let mut wet = 0.0f32;
			let mut w_top = NO_WATER;
			let mut submerged_z = NO_WATER;
			let sample_wet_half = river_half.max(p.voxel * 0.9);

			if river_d < sample_wet_half + river_valley {
				let mut depth = river_depth * ford_relief(&fords, wx, wz);
				let mut river_sheet = river_water_z;
				if shore < ESTUARY_BLEND_METRES && river_sheet > atlas {
					let estuary_t = if shore <= 0.0 {
						1.0
					} else {
						1.0 - (shore / ESTUARY_BLEND_METRES).clamp(0.0, 1.0)
					};
					river_sheet = lerpf(river_sheet, atlas, estuary_t);
				}
				let mut draped = river_sheet.min(h);
				if h > river_sheet + MAX_CHORD_BURY * CHORD_BREAK_FACTOR {
					draped = river_sheet;
				} else {
					draped = draped.max(h - MAX_CHORD_BURY);
				}
				let channel_water = draped - WATER_FREEBOARD;
				if shore < COASTAL_BED_BLEND_METRES && h < atlas + 10.0 {
					let coast_t = if shore <= 0.0 {
						1.0
					} else {
						1.0 - (shore / COASTAL_BED_BLEND_METRES).clamp(0.0, 1.0)
					};
					let shelf_t = 1.0 - ((h - atlas) / 10.0).clamp(0.0, 1.0);
					let shallow = coast_t * shelf_t;
					let depth_cap = lerpf(depth, COASTAL_BED_MAX_BELOW_PLANE, shallow);
					depth = depth.min(depth_cap);
				}
				if river_d <= sample_wet_half {
					let across = river_d / sample_wet_half.max(0.001);
					let mut profile = (1.0 - across * across).max(0.0).sqrt();
					profile = profile.max(0.4);
					let mut bed = channel_water - (depth * profile).max(MIN_BED_CLEARANCE);
					if shore < COASTAL_BED_BLEND_METRES && h < atlas + 10.0 {
						bed = bed.max(atlas - COASTAL_BED_MAX_BELOW_PLANE);
					}
					surface = surface.min(bed);
					submerged_z = channel_water;
					w_top = channel_water;
				} else {
					let ramp = smoothstep(0.0, river_valley, river_d - sample_wet_half);
					surface = surface.min(lerpf(channel_water + BANK_RISE, surface, ramp));
				}
				wet = 1.0 - smoothstep(0.0, sample_wet_half + 12.0, river_d);
			}

			if has_sheet(lake_surf) {
				surface = surface.min(h.min(lake_surf) - MIN_BED_CLEARANCE);
				w_top = if has_sheet(w_top) {
					w_top.max(lake_surf)
				} else {
					lake_surf
				};
				submerged_z = if has_sheet(submerged_z) {
					submerged_z.max(lake_surf)
				} else {
					lake_surf
				};
				wet = wet.max(smoothstep(0.0, 2.5, lake_surf - h));
			} else if lake_edge <= p.macro_cell_size * 1.25 && river_d <= sample_wet_half {
				let spill_near = coerce_sheet(ch(grids, count, 9, index));
				if has_sheet(spill_near)
					&& has_sheet(river_water_z)
					&& (river_water_z - spill_near).abs() <= 2.0
				{
					let mut mouth = spill_near - WATER_FREEBOARD;
					if has_sheet(w_top) {
						mouth = w_top.min(mouth);
					}
					surface = surface.min(spill_near - MIN_BED_CLEARANCE);
					w_top = mouth;
					submerged_z = if has_sheet(submerged_z) {
						submerged_z.max(mouth)
					} else {
						mouth
					};
					wet = wet.max(1.0);
				}
			} else if !has_sheet(w_top)
				&& lake_edge <= p.macro_cell_size * 1.25
				&& river_d <= sample_wet_half * 1.35
			{
				let spill_near = coerce_sheet(ch(grids, count, 9, index));
				let drain = ch(grids, count, 8, index);
				if has_sheet(spill_near)
					&& drain > h + MIN_VISIBLE_WATER_CLEARANCE
					&& (drain - spill_near).abs() <= 2.0
				{
					let mut approach = drain.min(spill_near) - WATER_FREEBOARD;
					approach = approach.min(h - MIN_VISIBLE_WATER_CLEARANCE);
					surface = surface.min(approach - MIN_BED_CLEARANCE);
					w_top = approach;
					submerged_z = approach;
					wet = wet.max(1.0);
				}
			}

			if has_sheet(atlas_surface) {
				surface = surface.min(h.min(atlas_surface) - MIN_BED_CLEARANCE);
				w_top = atlas_surface;
				submerged_z = atlas_surface;
				wet = wet.max(smoothstep(0.0, 2.5, atlas_surface - h));
			}

			let gap = axial_bridge_gap(&bridge_grades, wx, wz);
			let mut road_amt = 0.0f32;
			let cut_depth = (surface - road_z).max(0.0);
			let mut shoulder = 14.0f32;
			if cut_depth > 0.5 {
				shoulder = (14.0 + cut_depth * 1.5).min(56.0);
			}
			if road_d < road_half + shoulder + 2.0 {
				let bench = 1.0 - smoothstep(road_half, road_half + shoulder, road_d);
				let mut bench_z = road_z;
				if has_sheet(submerged_z) {
					bench_z = road_z.min(submerged_z - 0.1);
				}
				surface = lerpf(surface, bench_z, bench * (1.0 - gap));
				road_amt = 1.0 - smoothstep(road_half * 0.6, road_half + 1.6, road_d);
			}

			let mut error = 0.0f32;
			if has_sheet(w_top) {
				has_water = true;
				wet_columns += 1;
				let clearance = w_top - surface;
				min_water_clearance = min_water_clearance.min(clearance);
				let need = w_top - MIN_VISIBLE_WATER_CLEARANCE;
				error = (surface - need).max(0.0);
				if clearance < MIN_VISIBLE_WATER_CLEARANCE {
					wet_columns_failing += 1;
				}
				worst_error = worst_error.max(error);
			} else if has_sheet(submerged_z) {
				error = (surface - submerged_z).max(0.0);
				worst_error = worst_error.max(error);
			}

			if !(surface.is_finite() && surface > NO_WATER_THRESH) {
				panic!("build_columns surface[{index}] is not land height ({surface})");
			}
			surface_z[index] = surface;
			corridor_mask[index] = mask;
			wetness[index] = wet.clamp(0.0, 1.0);
			roadness[index] = road_amt.clamp(0.0, 1.0);
			biome[index] = biome_id;
			temperature_out[index] = temp;
			ground_color_out[index] = tint;
			overhang_amp[index] =
				(amp - p.relief_amp_plains).max(0.0) * p.overhang_amount * mask * mask;
			contract_error[index] = error;
			water_top[index] = if has_sheet(w_top) { w_top } else { NO_WATER };
			river_dist[index] = river_d;
			wet_half_of[index] = sample_wet_half;
		}
	}

	worst_error = suppress_ground_over_water(
		&mut surface_z,
		&mut water_top,
		&mut wetness,
		&mut contract_error,
		&river_dist,
		&wet_half_of,
		samples_h,
		p.voxel,
		worst_error,
		&mut has_water,
		&mut wet_columns,
		&mut wet_columns_failing,
		&mut min_water_clearance,
	);
	apply_bridge_grades(
		&mut surface_z,
		&mut water_top,
		&mut wetness,
		&bridge_grades,
		samples_h,
		p.origin_x,
		p.origin_z,
		p.voxel,
	);
	damp_overhangs(&mut overhang_amp, &surface_z, samples_h, p.voxel);

	// Bind packed arrays to locals before Dictionary::set so temporaries cannot
	// collapse to a shared/invalid buffer across keys (gdext Variant insert).
	let surface_arr = PackedFloat32Array::from(surface_z);
	let corridor_arr = PackedFloat32Array::from(corridor_mask);
	let wetness_arr = PackedFloat32Array::from(wetness);
	let roadness_arr = PackedFloat32Array::from(roadness);
	let biome_arr = PackedByteArray::from(biome);
	let temperature_arr = PackedFloat32Array::from(temperature_out);
	let ground_color_arr = PackedColorArray::from(ground_color_out);
	let overhang_arr = PackedFloat32Array::from(overhang_amp);
	let contract_arr = PackedFloat32Array::from(contract_error);
	let water_arr = PackedFloat32Array::from(water_top);

	let mut out = Dictionary::<Variant, Variant>::new();
	out.set("surface_z", &surface_arr);
	out.set("corridor_mask", &corridor_arr);
	out.set("wetness", &wetness_arr);
	out.set("roadness", &roadness_arr);
	out.set("biome", &biome_arr);
	out.set("temperature", &temperature_arr);
	out.set("ground_color", &ground_color_arr);
	out.set("overhang_amp", &overhang_arr);
	out.set("contract_error", &contract_arr);
	out.set("water_top", &water_arr);
	out.set("has_water", has_water);
	out.set("wet_columns", wet_columns);
	out.set("wet_columns_failing_clearance", wet_columns_failing);
	out.set("min_water_clearance", min_water_clearance);
	out.set("max_contract_error", worst_error);
	let _ = RIVER_STRIDE;
	let _ = ROAD_STRIDE;
	out
}

#[inline]
fn coerce_sheet(z: f32) -> f32 {
	if z.is_finite() && z > NO_WATER_THRESH {
		z
	} else {
		NO_WATER
	}
}

fn suppress_ground_over_water(
	surface_z: &mut [f32],
	water_top: &mut [f32],
	wetness: &mut [f32],
	contract_error: &mut [f32],
	river_dist: &[f32],
	wet_half_of: &[f32],
	samples_h: usize,
	voxel: f32,
	worst_error: f32,
	has_water: &mut bool,
	wet_columns: &mut i32,
	wet_columns_failing: &mut i32,
	min_water_clearance: &mut f32,
) -> f32 {
	let last = samples_h as i32 - 1;
	let offsets = [(1i32, 0i32), (-1, 0), (0, 1), (0, -1)];
	for iz in 0..samples_h {
		for ix in 0..samples_h {
			let index = iz * samples_h + ix;
			let top = water_top[index];
			if !has_sheet(top) {
				continue;
			}
			let need = top - MIN_VISIBLE_WATER_CLEARANCE;
			if surface_z[index] >= need {
				surface_z[index] = need - MIN_BED_CLEARANCE * 0.5;
			}
			for (ox, oz) in offsets {
				let nx = ix as i32 + ox;
				let nz = iz as i32 + oz;
				if nx < 0 || nz < 0 || nx > last || nz > last {
					continue;
				}
				let ni = nz as usize * samples_h + nx as usize;
				if surface_z[ni] < top - MIN_VISIBLE_WATER_CLEARANCE {
					continue;
				}
				let n_half = wet_half_of[ni].max(wet_half_of[index]);
				if river_dist[ni] <= n_half * 1.05 {
					surface_z[ni] = top - MIN_BED_CLEARANCE;
					water_top[ni] = top;
					wetness[ni] = wetness[ni].max(0.9);
					*has_water = true;
				} else if river_dist[ni] <= n_half + voxel {
					surface_z[ni] = surface_z[ni].min(top + BANK_RISE);
				}
			}
		}
	}

	*wet_columns = 0;
	*wet_columns_failing = 0;
	*min_water_clearance = NO_CLEARANCE;
	let mut err = 0.0f32;
	for i in 0..surface_z.len() {
		let top = water_top[i];
		if !has_sheet(top) {
			contract_error[i] = 0.0;
			continue;
		}
		*wet_columns += 1;
		let clearance = top - surface_z[i];
		*min_water_clearance = min_water_clearance.min(clearance);
		let need = top - MIN_VISIBLE_WATER_CLEARANCE;
		let col_err = (surface_z[i] - need).max(0.0);
		contract_error[i] = col_err;
		err = err.max(col_err);
		if clearance < MIN_VISIBLE_WATER_CLEARANCE {
			*wet_columns_failing += 1;
		}
	}
	worst_error.max(err)
}

fn apply_bridge_grades(
	surface_z: &mut [f32],
	water_top: &mut [f32],
	wetness: &mut [f32],
	grades: &PackedFloat32Array,
	samples_h: usize,
	origin_x: f32,
	origin_z: f32,
	voxel: f32,
) {
	if grades.is_empty() {
		return;
	}
	let count = grades.len() / BRIDGE_GRADE_STRIDE;
	let contact_r2 = BRIDGE_CONTACT_RADIUS * BRIDGE_CONTACT_RADIUS;
	for iz in 0..samples_h {
		let wz = origin_z + iz as f32 * voxel;
		for ix in 0..samples_h {
			let wx = origin_x + ix as f32 * voxel;
			let index = iz * samples_h + ix;
			let mut surface = surface_z[index];
			for gi in 0..count {
				let base = gi * BRIDGE_GRADE_STRIDE;
				let cx = grades[base];
				let cz = grades[base + 1];
				let ax = grades[base + 2];
				let az = grades[base + 3];
				let deck_z = grades[base + 4];
				let gap_half = grades[base + 5];
				let abut_s = grades[base + 6];
				let ramp_len = grades[base + 7];
				let half_w = grades[base + 8];
				let plateau = grades[base + 9];
				let hard_end = abut_s + plateau;
				let dx = wx - cx;
				let dz = wz - cz;
				let along = dx * ax + dz * az;
				let abs_along = along.abs();
				let lateral = (dx * az - dz * ax).abs();
				if lateral > half_w || abs_along > hard_end + ramp_len {
					continue;
				}
				if abs_along < gap_half {
					continue;
				}
				let lat_w = 1.0 - smoothstep(half_w * 0.45, half_w, lateral);
				if lat_w <= 0.001 {
					continue;
				}
				let abut_sign = if along >= 0.0 { 1.0 } else { -1.0 };
				let abut_x = cx + ax * abut_s * abut_sign;
				let abut_z = cz + az * abut_s * abut_sign;
				let near_abut = (wx - abut_x).powi(2) + (wz - abut_z).powi(2) <= contact_r2;
				if near_abut || abs_along <= hard_end {
					let apron_w = if near_abut || lateral < half_w * 0.4 {
						1.0
					} else {
						lat_w
					};
					surface = lerpf(surface, deck_z, apron_w);
					if apron_w > 0.85
						&& has_sheet(water_top[index])
						&& deck_z >= water_top[index] - 0.05
					{
						water_top[index] = NO_WATER;
						wetness[index] = wetness[index].min(0.2);
					}
					continue;
				}
				let t = ((abs_along - hard_end) / ramp_len.max(0.001)).clamp(0.0, 1.0);
				let natural = surface;
				let target = lerpf(deck_z, natural, t * t);
				let mut ramp_w = lat_w;
				if natural > deck_z + 0.15 {
					ramp_w = lat_w.max(0.9);
				} else if natural < deck_z - 0.15 {
					ramp_w = lat_w.max(0.85);
				}
				surface = lerpf(surface, target, ramp_w);
			}
			surface_z[index] = surface;
		}
	}
}

fn damp_overhangs(overhang_amp: &mut [f32], surface: &[f32], samples_h: usize, voxel: f32) {
	let last = samples_h - 1;
	let run = voxel * 2.0;
	for iz in 0..samples_h {
		for ix in 0..samples_h {
			let index = iz * samples_h + ix;
			if overhang_amp[index] <= 0.05 {
				continue;
			}
			let west = surface[iz * samples_h + ix.saturating_sub(1)];
			let east = surface[iz * samples_h + (ix + 1).min(last)];
			let north = surface[iz.saturating_sub(1) * samples_h + ix];
			let south = surface[(iz + 1).min(last) * samples_h + ix];
			let slope = (((east - west).powi(2) + (south - north).powi(2)).sqrt()) / run;
			overhang_amp[index] *= 1.0 - 0.9 * smoothstep(1.1, 2.1, slope);
		}
	}
}
