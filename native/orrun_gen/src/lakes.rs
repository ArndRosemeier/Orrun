//! Local lake extraction — bit-compatible with `Hydrology._find_lakes`.

use godot::prelude::*;

const NEIGHBOR_DX: [i32; 8] = [1, 1, 0, -1, -1, -1, 0, 1];
const NEIGHBOR_DZ: [i32; 8] = [0, 1, 1, 1, 0, -1, -1, -1];

pub struct LakeParams {
	pub cells: i32,
	pub cell_size: f32,
	pub origin_x: i32,
	pub origin_z: i32,
	pub local_min_x: i32,
	pub local_min_z: i32,
	pub local_max_x: i32,
	pub local_max_z: i32,
	pub lake_epsilon: f32,
	pub surface_tol: f32,
	pub local_lake_max_span: f32,
	pub lake_min_cells: i32,
	pub lake_max_cells: i32,
	pub lake_min_depth: f32,
}

pub fn find_lakes(
	elevation: PackedFloat32Array,
	filled: PackedFloat32Array,
	sink_mask: PackedByteArray,
	receiver: PackedInt32Array,
	accumulation: PackedFloat32Array,
	p: LakeParams,
) -> Dictionary<Variant, Variant> {
	let n = p.cells as usize;
	let count = n * n;
	assert_eq!(elevation.len(), count);
	assert_eq!(filled.len(), count);
	assert_eq!(sink_mask.len(), count);
	assert_eq!(receiver.len(), count);
	assert_eq!(accumulation.len(), count);

	let mut lake_id = vec![-1i32; count];
	let mut stack: Vec<i32> = Vec::new();

	let mut surfaces: Vec<f32> = Vec::new();
	let mut depths: Vec<f32> = Vec::new();
	let mut outlets: Vec<i32> = Vec::new();
	let mut bounds: Vec<f32> = Vec::new();
	let mut member_offsets: Vec<i32> = vec![0];
	let mut members_all: Vec<i32> = Vec::new();

	let in_local = |index: usize| -> bool {
		let cx = (index % n) as i32;
		let cz = (index / n) as i32;
		cx >= p.local_min_x
			&& cz >= p.local_min_z
			&& cx <= p.local_max_x
			&& cz <= p.local_max_z
	};

	let cell_center = |cx: i32, cz: i32| -> (f32, f32) {
		(
			(p.origin_x as f32 + cx as f32 + 0.5) * p.cell_size,
			(p.origin_z as f32 + cz as f32 + 0.5) * p.cell_size,
		)
	};

	for start in 0..count {
		if lake_id[start] != -1 {
			continue;
		}
		if filled[start] - elevation[start] <= p.lake_epsilon {
			continue;
		}

		let surface = filled[start];
		let provisional_id = surfaces.len() as i32;

		stack.clear();
		stack.push(start as i32);
		lake_id[start] = provisional_id;

		let mut members: Vec<i32> = Vec::new();
		let mut deepest = 0.0f32;
		let mut min_x = f32::INFINITY;
		let mut min_z = f32::INFINITY;
		let mut max_x = f32::NEG_INFINITY;
		let mut max_z = f32::NEG_INFINITY;
		let mut rejected = false;

		while let Some(cell) = stack.pop() {
			let cell_u = cell as usize;
			members.push(cell);
			deepest = deepest.max(surface - elevation[cell_u]);

			let cx = (cell_u % n) as i32;
			let cz = (cell_u / n) as i32;
			if !in_local(cell_u) {
				rejected = true;
			}
			if sink_mask[cell_u] != 0 {
				rejected = true;
			}
			let (wx, wz) = cell_center(cx, cz);
			min_x = min_x.min(wx);
			max_x = max_x.max(wx);
			min_z = min_z.min(wz);
			max_z = max_z.max(wz);

			for k in 0..8 {
				let nx = cx + NEIGHBOR_DX[k];
				let nz = cz + NEIGHBOR_DZ[k];
				if nx < 0 || nz < 0 || nx >= n as i32 || nz >= n as i32 {
					continue;
				}
				let nb = nz as usize * n + nx as usize;
				if lake_id[nb] != -1 {
					continue;
				}
				if filled[nb] - elevation[nb] <= p.lake_epsilon {
					continue;
				}
				if (filled[nb] - surface).abs() > p.surface_tol {
					continue;
				}
				lake_id[nb] = provisional_id;
				stack.push(nb as i32);
			}
		}

		let span = (max_x - min_x).max(max_z - min_z) + p.cell_size;
		if rejected
			|| members.len() < p.lake_min_cells as usize
			|| members.len() > p.lake_max_cells as usize
			|| span > p.local_lake_max_span
			|| deepest < p.lake_min_depth
		{
			for cell in &members {
				lake_id[*cell as usize] = -1;
			}
			continue;
		}

		let half = p.cell_size * 0.5;
		let outlet = find_outlet(&members, &receiver, &accumulation, &lake_id, provisional_id);

		surfaces.push(surface);
		depths.push(deepest);
		outlets.push(outlet);
		bounds.extend_from_slice(&[
			min_x - half,
			min_z - half,
			(max_x - min_x) + p.cell_size,
			(max_z - min_z) + p.cell_size,
		]);
		members_all.extend_from_slice(&members);
		member_offsets.push(members_all.len() as i32);
	}

	// Remap provisional ids to dense 0..lakes-1 (already dense if we only keep accepted).
	// Rejected basins cleared ids to -1; accepted kept provisional_id == final id because
	// we only increment surfaces on accept. Provisional was surfaces.len() before push,
	// which equals final id. Good.

	let mut out = Dictionary::<Variant, Variant>::new();
	let lake_id_arr = PackedInt32Array::from(lake_id);
	let surface_arr = PackedFloat32Array::from(surfaces);
	let depth_arr = PackedFloat32Array::from(depths);
	let outlet_arr = PackedInt32Array::from(outlets);
	let bounds_arr = PackedFloat32Array::from(bounds);
	let offsets_arr = PackedInt32Array::from(member_offsets);
	let members_arr = PackedInt32Array::from(members_all);
	out.set("lake_id", &lake_id_arr);
	out.set("surface", &surface_arr);
	out.set("max_depth", &depth_arr);
	out.set("outlet", &outlet_arr);
	out.set("bounds", &bounds_arr);
	out.set("member_offsets", &offsets_arr);
	out.set("members", &members_arr);
	out
}

fn find_outlet(
	members: &[i32],
	receiver: &PackedInt32Array,
	accumulation: &PackedFloat32Array,
	lake_id: &[i32],
	lake: i32,
) -> i32 {
	let mut best = -1i32;
	let mut best_acc = -1.0f32;
	for &cell in members {
		let down = receiver[cell as usize];
		if down < 0 {
			return cell;
		}
		if lake_id[down as usize] != lake && accumulation[cell as usize] > best_acc {
			best_acc = accumulation[cell as usize];
			best = cell;
		}
	}
	best
}
