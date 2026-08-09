//! Bucket-queue priority flood + flow accumulation.
//!
//! Bit-compatible with `Hydrology._priority_flood` / `_accumulate` in GDScript.

use godot::prelude::*;

const NEIGHBOR_DX: [i32; 8] = [1, 1, 0, -1, -1, -1, 0, 1];
const NEIGHBOR_DZ: [i32; 8] = [0, 1, 1, 1, 0, -1, -1, -1];

pub fn priority_flood(
	elevation: PackedFloat32Array,
	sink_mask: PackedByteArray,
	outflow_cells: PackedInt32Array,
	cells: i32,
	min_elevation: f32,
	max_elevation: f32,
	level_step: f32,
) -> Dictionary<Variant, Variant> {
	let n = cells as usize;
	let count = n * n;
	assert_eq!(elevation.len(), count, "elevation length");
	assert_eq!(sink_mask.len(), count, "sink_mask length");
	assert!(level_step > 0.0);

	let mut filled = vec![0.0f32; count];
	let mut receiver = vec![-1i32; count];
	let mut flow_order = vec![0i32; count];
	let mut visited = vec![0u8; count];

	let base = min_elevation;
	let levels = (((max_elevation - base) / level_step) as i32 + 4).max(1) as usize;
	let mut buckets: Vec<Vec<i32>> = vec![Vec::new(); levels];
	let mut head = vec![0usize; levels];

	let seed = |buckets: &mut [Vec<i32>],
	            visited: &mut [u8],
	            filled: &mut [f32],
	            receiver: &mut [i32],
	            elevation: &PackedFloat32Array,
	            index: usize| {
		if visited[index] != 0 {
			return;
		}
		visited[index] = 1;
		let elev = elevation[index];
		filled[index] = elev;
		receiver[index] = -1;
		let level = ((elev - base) / level_step) as i32;
		let level = level.clamp(0, levels as i32 - 1) as usize;
		buckets[level].push(index as i32);
	};

	for cz in 0..n {
		for cx in 0..n {
			let index = cz * n + cx;
			let edge = cx == 0 || cz == 0 || cx == n - 1 || cz == n - 1;
			if edge || sink_mask[index] != 0 {
				seed(
					&mut buckets,
					&mut visited,
					&mut filled,
					&mut receiver,
					&elevation,
					index,
				);
			}
		}
	}
	for i in 0..outflow_cells.len() {
		let index = outflow_cells[i];
		if index < 0 || index as usize >= count {
			continue;
		}
		seed(
			&mut buckets,
			&mut visited,
			&mut filled,
			&mut receiver,
			&elevation,
			index as usize,
		);
	}

	let mut level = 0usize;
	let mut popped = 0usize;
	while level < levels {
		if head[level] >= buckets[level].len() {
			level += 1;
			continue;
		}
		let cell_index = buckets[level][head[level]] as usize;
		head[level] += 1;
		flow_order[popped] = cell_index as i32;
		popped += 1;

		let cx = cell_index % n;
		let cz = cell_index / n;
		let cell_filled = filled[cell_index];
		for k in 0..8 {
			let nx = cx as i32 + NEIGHBOR_DX[k];
			let nz = cz as i32 + NEIGHBOR_DZ[k];
			if nx < 0 || nz < 0 || nx >= n as i32 || nz >= n as i32 {
				continue;
			}
			let nb = nz as usize * n + nx as usize;
			if visited[nb] != 0 {
				continue;
			}
			visited[nb] = 1;
			let nb_filled = elevation[nb].max(cell_filled);
			filled[nb] = nb_filled;
			receiver[nb] = cell_index as i32;
			let nb_level = level.max(((nb_filled - base) / level_step) as usize);
			let nb_level = nb_level.min(levels - 1);
			buckets[nb_level].push(nb as i32);
		}
	}

	assert_eq!(
		popped, count,
		"priority flood left {} cells unreached",
		count - popped
	);

	let filled_arr = PackedFloat32Array::from(filled);
	let receiver_arr = PackedInt32Array::from(receiver);
	let order_arr = PackedInt32Array::from(flow_order);
	let mut out = Dictionary::<Variant, Variant>::new();
	out.set("filled", &filled_arr);
	out.set("receiver", &receiver_arr);
	out.set("flow_order", &order_arr);
	out
}

pub fn accumulate(
	flow_order: PackedInt32Array,
	receiver: PackedInt32Array,
	moisture: PackedFloat32Array,
	inflow_boosts: PackedFloat32Array,
) -> PackedFloat32Array {
	let count = flow_order.len();
	assert_eq!(receiver.len(), count);
	assert_eq!(moisture.len(), count);

	let mut accumulation = vec![0.0f32; count];
	for i in 0..count {
		accumulation[i] = 0.55 + moisture[i] * 0.9;
	}

	let boosts = inflow_boosts.len() / 2 * 2;
	let mut b = 0;
	while b < boosts {
		let index = inflow_boosts[b] as i32;
		let amount = inflow_boosts[b + 1];
		if index >= 0 && (index as usize) < count {
			accumulation[index as usize] += amount;
		}
		b += 2;
	}

	for i in (0..count).rev() {
		let cell_index = flow_order[i] as usize;
		let down = receiver[cell_index];
		if down >= 0 {
			accumulation[down as usize] += accumulation[cell_index];
		}
	}

	PackedFloat32Array::from(accumulation)
}
