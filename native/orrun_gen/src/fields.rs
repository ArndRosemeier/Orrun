//! Atlas field sampling (Catmull-Rom / bilinear) matching `AtlasFields`.

use godot::prelude::PackedFloat32Array;

const ATLAS_CELL: f32 = 1000.0;

#[inline]
fn index_of(size: i32, ax: i32, az: i32) -> usize {
	let last = size - 1;
	let x = ax.clamp(0, last);
	let z = az.clamp(0, last);
	(z * size + x) as usize
}

#[inline]
fn catmull(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
	let t2 = t * t;
	let t3 = t2 * t;
	0.5 * (2.0 * p1
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
}

fn row(field: &PackedFloat32Array, size: i32, ix: i32, az: i32, tx: f32) -> f32 {
	catmull(
		field[index_of(size, ix - 1, az)],
		field[index_of(size, ix, az)],
		field[index_of(size, ix + 1, az)],
		field[index_of(size, ix + 2, az)],
		tx,
	)
}

pub fn sample_smooth(field: &PackedFloat32Array, size: i32, world_x: f32, world_z: f32) -> f32 {
	let u = world_x / ATLAS_CELL - 0.5;
	let v = world_z / ATLAS_CELL - 0.5;
	let ix = u.floor() as i32;
	let iz = v.floor() as i32;
	let tx = u - ix as f32;
	let tz = v - iz as f32;
	catmull(
		row(field, size, ix, iz - 1, tx),
		row(field, size, ix, iz, tx),
		row(field, size, ix, iz + 1, tx),
		row(field, size, ix, iz + 2, tx),
		tz,
	)
}

pub fn sample_linear(field: &PackedFloat32Array, size: i32, world_x: f32, world_z: f32) -> f32 {
	let u = world_x / ATLAS_CELL - 0.5;
	let v = world_z / ATLAS_CELL - 0.5;
	let ix = u.floor() as i32;
	let iz = v.floor() as i32;
	let tx = u - ix as f32;
	let tz = v - iz as f32;
	let a = field[index_of(size, ix, iz)] * (1.0 - tx) + field[index_of(size, ix + 1, iz)] * tx;
	let b =
		field[index_of(size, ix, iz + 1)] * (1.0 - tx) + field[index_of(size, ix + 1, iz + 1)] * tx;
	a * (1.0 - tz) + b * tz
}
