//! 3D density volume fill — matches `DensityField._build_volume`.

use godot::prelude::*;

use crate::noise::Noise3D;

const SOLID: f32 = 1.0e6;
const AIR: f32 = -1.0e6;
const CAVE_SOLID_CAP: f32 = 9.0;
const CAVE_STRENGTH: f32 = 26.0;
/// Matches columns.rs — dry water marker across the FFI (not ±INF).
const NO_WATER_THRESH: f32 = -1.0e19;

#[inline]
fn has_sheet(z: f32) -> bool {
	z.is_finite() && z > NO_WATER_THRESH
}

#[inline]
fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
	let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
	t * t * (3.0 - 2.0 * t)
}

pub struct VolumeParams {
	pub samples_h: i32,
	pub voxel: f32,
	pub origin_x: f32,
	pub origin_z: f32,
	pub surface_band: f32,
	pub vertical_margin: f32,
	pub world_floor: f32,
	pub world_ceiling: f32,
	pub cave_enabled: bool,
	pub cave_top_depth: f32,
	pub cave_bottom_depth: f32,
	pub cave_threshold: f32,
	pub cave_water_clearance: f32,
	pub seed_overhang: i32,
	pub overhang_scale: f32,
	pub seed_cave_a: i32,
	pub seed_cave_b: i32,
	pub cave_scale: f32,
}

pub fn build_volume(
	surface_z: PackedFloat32Array,
	corridor_mask: PackedFloat32Array,
	water_top: PackedFloat32Array,
	overhang_amp: PackedFloat32Array,
	p: VolumeParams,
) -> Dictionary<Variant, Variant> {
	let samples_h = p.samples_h as usize;
	let count = samples_h * samples_h;
	assert_eq!(surface_z.len(), count);
	// Borrow packed storage; do not rayon here — ChunkJob already runs on
	// Godot's WorkerThreadPool, and nested rayon pools deadlock under load.
	let surface_z = surface_z.as_slice();
	let corridor_mask = corridor_mask.as_slice();
	let water_top = water_top.as_slice();
	let overhang_amp = overhang_amp.as_slice();
	assert_eq!(surface_z.len(), count);
	assert_eq!(corridor_mask.len(), count);
	assert_eq!(water_top.len(), count);
	assert_eq!(overhang_amp.len(), count);

	let mut lowest = f32::INFINITY;
	let mut highest = f32::NEG_INFINITY;
	for i in 0..count {
		let s = surface_z[i];
		if !(s.is_finite() && s > NO_WATER_THRESH) {
			panic!("build_volume: surface_z[{i}] is not a land height ({s})");
		}
		lowest = lowest.min(s);
		highest = highest.max(s);
	}
	let band_max = p.surface_band + p.voxel * 2.0;

	let mut y_min = lowest - band_max - p.vertical_margin;
	if p.cave_enabled {
		y_min = y_min.min(lowest - p.cave_bottom_depth - p.vertical_margin);
	}
	let mut y_max = highest + band_max + p.vertical_margin;
	y_min = ((y_min.clamp(p.world_floor, p.world_ceiling) / p.voxel).floor() * p.voxel)
		.max(p.world_floor);
	y_max = ((y_max.clamp(p.world_floor, p.world_ceiling) / p.voxel).ceil() * p.voxel)
		.min(p.world_ceiling);

	let samples_y = (((y_max - y_min) / p.voxel).round() as i32 + 1).max(2) as usize;
	let mut values = vec![0.0f32; samples_h * samples_y * samples_h];

	let overhang = Noise3D::from_period_fbm(p.seed_overhang, p.overhang_scale, 3, 0.55, 2.0);
	let cave_a = Noise3D::from_period_fbm(p.seed_cave_a, p.cave_scale, 2, 0.5, 2.0);
	let cave_b = Noise3D::from_period_fbm(p.seed_cave_b, p.cave_scale * 0.77, 2, 0.5, 2.0);

	for iz in 0..samples_h {
		let wz = p.origin_z + iz as f32 * p.voxel;
		for ix in 0..samples_h {
			let wx = p.origin_x + ix as f32 * p.voxel;
			let column = iz * samples_h + ix;
			let surface = surface_z[column];
			let mask = corridor_mask[column];
			let water = water_top[column];
			let overhang_amp_c = overhang_amp[column];
			let band = overhang_amp_c + p.surface_band * 0.35 + p.voxel * 2.0;

			let mut cave_allow = p.cave_enabled && mask > 0.35;
			let mut cave_ceiling = surface - p.cave_top_depth;
			let cave_floor = surface - p.cave_bottom_depth;
			if cave_allow && has_sheet(water) {
				cave_ceiling = cave_ceiling.min(water - p.cave_water_clearance);
				if cave_ceiling <= cave_floor {
					cave_allow = false;
				}
			}

			for iy in 0..samples_y {
				let wy = y_min + iy as f32 * p.voxel;
				let base = surface - wy;
				let mut value = base;

				// Deep uniform slabs: one compare, no noise / cave work.
				if base > band + 1.0 {
					values[(iz * samples_y + iy) * samples_h + ix] = SOLID;
					continue;
				}
				if base < -band - 1.0 {
					values[(iz * samples_y + iy) * samples_h + ix] = AIR;
					continue;
				}

				if base > band {
					value = base;
				} else if base < -band {
					value = base;
				} else if overhang_amp_c > 0.05 {
					value = base + overhang.get(wx, wy, wz) * overhang_amp_c;
				}

				if cave_allow && wy < cave_ceiling && wy > cave_floor && value > 0.0 {
					let ca = cave_a.get(wx, wy * 1.65, wz);
					let cb = cave_b.get(wx + 411.0, wy * 1.65, wz - 233.0);
					let tube = p.cave_threshold - (ca * ca + cb * cb).sqrt() * 3.4;
					if tube > 0.0 {
						let taper = smoothstep(0.0, 6.0, cave_ceiling - wy)
							.min(smoothstep(0.0, 8.0, wy - cave_floor));
						value = value.min(CAVE_SOLID_CAP) - tube * CAVE_STRENGTH * taper;
					}
				}

				values[(iz * samples_y + iy) * samples_h + ix] = value;
			}
		}
	}

	let mut out = Dictionary::<Variant, Variant>::new();
	out.set("values", &PackedFloat32Array::from(values));
	out.set("origin_y", y_min);
	out.set("samples_y", samples_y as i32);
	out
}
