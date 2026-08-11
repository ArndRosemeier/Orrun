//! Atlas landmask + elevation/humidity/relief codes — `ContinentAtlas._build_landmask_elevation`.

use godot::prelude::*;

use crate::noise::Noise2D;

const OCEAN_COLLAR_FULL: i32 = 48;
const SIZE_FULL: i32 = 1000;

pub struct LandmaskParams {
	pub size: i32,
	pub seed_continent: i32,
	pub seed_coast_cut: i32,
	pub seed_peninsula: i32,
	pub seed_mountain: i32,
	pub seed_moist: i32,
	pub seed_relief: i32,
	pub seed_warp: i32,
	pub seed_warp2: i32,
	pub seed_basin: i32,
}

pub fn build_landmask(p: LandmaskParams) -> Dictionary<Variant, Variant> {
	let size = p.size as usize;
	let count = size * size;

	let continent = Noise2D::atlas_fbm(p.seed_continent, 0.0024, 6);
	let coast_cut = Noise2D::atlas_ridged(p.seed_coast_cut, 0.011, 4);
	let peninsula = Noise2D::atlas_fbm(p.seed_peninsula, 0.0065, 4);
	let mountain = Noise2D::atlas_ridged(p.seed_mountain, 0.0045, 4);
	let moist = Noise2D::atlas_fbm(p.seed_moist, 0.0035, 3);
	let relief_n = Noise2D::atlas_fbm(p.seed_relief, 0.008, 3);
	let warp = Noise2D::atlas_fbm(p.seed_warp, 0.0035, 4);
	let warp2 = Noise2D::atlas_fbm(p.seed_warp2, 0.0016, 3);
	// Mid-scale valley / basin field. Ridged highs are divides; lows become
	// closed catchments once amplitude exceeds local slope.
	let basin_ridge = Noise2D::atlas_ridged(p.seed_basin, 0.011, 4);
	let basin_fbm = Noise2D::atlas_fbm(p.seed_basin ^ 0x5F3759DF_u32 as i32, 0.0075, 3);
	let basin_large = Noise2D::atlas_fbm(p.seed_basin.wrapping_add(0x27D4_EB2D), 0.0032, 3);

	let half = p.size as f32 * 0.5;
	let collar_cells = collar_cells(p.size);
	let soft_margin = collar_cells as f32 + p.size as f32 * 0.02;

	let mut land = vec![0u8; count];
	let mut elev_code = vec![0u8; count];
	let mut humidity = vec![0u8; count];
	let mut relief = vec![0u8; count];

	for az in 0..size {
		for ax in 0..size {
			let idx = az * size + ax;
			let edge_d = (ax as i32)
				.min(p.size - 1 - ax as i32)
				.min(az as i32)
				.min(p.size - 1 - az as i32);
			let hard_sea = edge_d < collar_cells;
			let dxn = (ax as f32 - half) / half;
			let dzn = (az as f32 - half) / half;
			let radial = (dxn * dxn + dzn * dzn).sqrt();
			let ax_f = ax as f32;
			let az_f = az as f32;
			let wx = ax_f
				+ warp.get(ax_f, az_f) * p.size as f32 * 0.08
				+ warp2.get(az_f, ax_f) * p.size as f32 * 0.05;
			let wz = az_f
				+ warp.get(ax_f + 40.0, az_f - 17.0) * p.size as f32 * 0.08
				+ warp2.get(ax_f - 11.0, az_f + 27.0) * p.size as f32 * 0.05;
			let cont = continent.get(wx, wz);
			let pen = peninsula.get(wx * 0.7, wz * 0.7);
			let cut = coast_cut.get(wx, wz) * 0.5 + 0.5;
			let mut mass = 1.0 - (radial * 0.88).clamp(0.0, 1.20);
			mass = smoothstep(-0.08, 0.82, mass);
			let mut landness = cont * 0.66 + pen * 0.22 + mass * 0.56;
			landness -= cut * lerp(0.06, 0.30, radial.clamp(0.0, 1.0));
			let rim = smoothstep(soft_margin, soft_margin + p.size as f32 * 0.06, edge_d as f32);
			landness *= lerp(0.34, 1.0, rim);
			let is_land = (!hard_sea) && landness > 0.08;
			land[idx] = if is_land { 1 } else { 0 };

			if !is_land {
				let depth = (0.55 - landness).clamp(0.0, 1.0) * 32.0;
				elev_code[idx] = (depth as i32).clamp(0, 32) as u8;
				humidity[idx] = 255;
				relief[idx] = 0;
				continue;
			}

			let ridge = mountain.get(wx * 0.9, wz * 0.9) * 0.5 + 0.5;
			let alpine = ridge.powf(1.35) * smoothstep(0.2, 0.7, landness);
			let mut code_f = 48.0 + landness * 70.0 + alpine * 130.0;
			code_f += relief_n.get(wx, wz) * 10.0;

			// Inland weight: kill basin cut near the ocean collar so coastal
			// plains are not carved into lagoon sheets.
			let inland = smoothstep(
				soft_margin + p.size as f32 * 0.05,
				soft_margin + p.size as f32 * 0.20,
				edge_d as f32,
			) * smoothstep(0.14, 0.48, landness);

			// Elongated valley floors from inverted ridged divides.
			let divide = basin_ridge.get(wx * 0.92, wz * 1.08) * 0.5 + 0.5;
			let valley = (1.0 - divide).powf(1.75);
			// Stretch basins along a warped axis so they are not round bowls.
			let wx_stretch = wx * 1.35 + wz * 0.22;
			let wz_stretch = wz * 0.55 - wx * 0.18;
			let dip_raw = -basin_fbm.get(wx_stretch, wz_stretch);
			let dip = dip_raw.max(0.0).powf(1.45);
			let big_raw = -basin_large.get(wx * 0.7, wz * 0.7);
			let big = big_raw.max(0.0).powf(2.35);

			let basin_cut = (valley * 20.0 + dip * 16.0 + big * 26.0) * inland;
			code_f -= basin_cut;

			elev_code[idx] = (code_f as i32).clamp(33, 255) as u8;
			relief[idx] = ((alpine * 50.0 + relief_n.get(wz, wx) * 8.0 + 4.0) as i32).clamp(0, 63) as u8;

			let mut h = moist.get(wx, wz) * 0.5 + 0.5;
			h = lerp(h, 0.85, radial.clamp(0.0, 1.0) * 0.35) * 0.35 + h * 0.65;
			h -= alpine * 0.25;
			// Basin floors hold moisture slightly better than ridges.
			h += (valley * 0.08 + dip * 0.05) * inland;
			humidity[idx] = ((h * 255.0) as i32).clamp(0, 255) as u8;
		}
	}

	let land_arr = PackedByteArray::from(land);
	let elev_arr = PackedByteArray::from(elev_code);
	let hum_arr = PackedByteArray::from(humidity);
	let rel_arr = PackedByteArray::from(relief);
	let mut out = Dictionary::<Variant, Variant>::new();
	out.set("land", &land_arr);
	out.set("elev_code", &elev_arr);
	out.set("humidity", &hum_arr);
	out.set("relief", &rel_arr);
	out
}

fn collar_cells(size: i32) -> i32 {
	(6).max(OCEAN_COLLAR_FULL * size / SIZE_FULL)
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
