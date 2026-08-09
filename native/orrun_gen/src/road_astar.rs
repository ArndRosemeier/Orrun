//! Coarse atlas road A* — matches `ContinentAtlas._road_astar`.

use godot::prelude::*;
use std::collections::BinaryHeap;
use std::cmp::Ordering;

const NEIGHBOR_DX: [i32; 4] = [1, 0, -1, 0];
const NEIGHBOR_DZ: [i32; 4] = [0, 1, 0, -1];

#[derive(Copy, Clone)]
struct OpenNode {
	f: f32,
	cell: i32,
}

impl PartialEq for OpenNode {
	fn eq(&self, other: &Self) -> bool {
		self.cell == other.cell
	}
}
impl Eq for OpenNode {}
impl PartialOrd for OpenNode {
	fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for OpenNode {
	fn cmp(&self, other: &Self) -> Ordering {
		// Min-heap via reverse f ordering.
		match other.f.partial_cmp(&self.f) {
			Some(o) => o,
			None => Ordering::Equal,
		}
		.then_with(|| self.cell.cmp(&other.cell))
	}
}

#[inline]
fn biome(cell: i32) -> i32 {
	(cell >> 16) & 0x3F
}
#[inline]
fn relief(cell: i32) -> i32 {
	(cell >> 22) & 0x3F
}
#[inline]
fn population(cell: i32) -> i32 {
	(cell >> 28) & 0xF
}

pub fn road_astar(
	cells: PackedInt32Array,
	elev_code: PackedByteArray,
	river_adjacent: PackedByteArray,
	river_channel: PackedByteArray,
	size: i32,
	start: i32,
	goal: i32,
	biome_ocean: i32,
	biome_lake: i32,
	biome_alpine: i32,
) -> PackedInt32Array {
	let n = size as usize;
	let count = n * n;
	if start < 0 || goal < 0 || start as usize >= count || goal as usize >= count {
		return PackedInt32Array::new();
	}
	if start == goal {
		return PackedInt32Array::from(vec![start]);
	}

	let mut gscore = vec![f32::INFINITY; count];
	let mut came = vec![-1i32; count];
	let mut closed = vec![false; count];
	gscore[start as usize] = 0.0;

	let goal_ax = goal % size;
	let goal_az = goal / size;
	let mut open = BinaryHeap::new();
	open.push(OpenNode {
		f: (goal_ax - start % size).abs() as f32 + (goal_az - start / size).abs() as f32,
		cell: start,
	});

	let mut expansions = 0i32;
	while let Some(OpenNode { cell: current, .. }) = open.pop() {
		if expansions >= 20000 {
			break;
		}
		expansions += 1;
		if current == goal {
			return reconstruct(&came, current);
		}
		let cu = current as usize;
		if closed[cu] {
			continue;
		}
		closed[cu] = true;

		let cx = current % size;
		let cz = current / size;
		for k in 0..4 {
			let nx = cx + NEIGHBOR_DX[k];
			let nz = cz + NEIGHBOR_DZ[k];
			if nx < 0 || nz < 0 || nx >= size || nz >= size {
				continue;
			}
			let nb = nz * size + nx;
			let nbu = nb as usize;
			if closed[nbu] {
				continue;
			}
			let cell_word = cells[nbu];
			let b = biome(cell_word);
			if b == biome_ocean || b == biome_lake {
				continue;
			}
			let mut step = 1.45;
			step += relief(cell_word) as f32 * 0.06;
			step += (elev_code[nbu] as i32 - elev_code[cu] as i32).abs() as f32 * 0.08;
			if b == biome_alpine {
				step += 0.5;
			}
			if river_channel[nbu] != 0 {
				step += 0.55;
			} else if river_adjacent[nbu] != 0 {
				step -= 0.2;
			}
			step -= (population(cell_word) as f32 * 0.035).min(0.45);
			let tentative = gscore[cu] + step.max(1.0);
			if tentative >= gscore[nbu] {
				continue;
			}
			came[nbu] = current;
			gscore[nbu] = tentative;
			let h = (nx - goal_ax).abs() as f32 + (nz - goal_az).abs() as f32;
			open.push(OpenNode {
				f: tentative + h,
				cell: nb,
			});
		}
	}
	PackedInt32Array::new()
}

fn reconstruct(came: &[i32], mut current: i32) -> PackedInt32Array {
	let mut path = Vec::new();
	path.push(current);
	while came[current as usize] >= 0 {
		current = came[current as usize];
		path.push(current);
	}
	path.reverse();
	PackedInt32Array::from(path)
}
