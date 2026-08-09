//! Surface-nets mesh extract — matches `MeshExtract.build`.

use godot::prelude::*;

const SKIRT_DEPTH_FACTOR: f32 = 0.75;
fn color_rgb(r: f32, g: f32, b: f32) -> Color {
	Color::from_rgba(r, g, b, 1.0)
}

const CORNER_OFFSET: [[i32; 3]; 8] = [
	[0, 0, 0],
	[1, 0, 0],
	[0, 1, 0],
	[1, 1, 0],
	[0, 0, 1],
	[1, 0, 1],
	[0, 1, 1],
	[1, 1, 1],
];
const EDGE_CORNERS: [[usize; 2]; 12] = [
	[0, 1],
	[2, 3],
	[4, 5],
	[6, 7],
	[0, 2],
	[1, 3],
	[4, 6],
	[5, 7],
	[0, 4],
	[1, 5],
	[2, 6],
	[3, 7],
];

#[inline]
fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
	let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
	t * t * (3.0 - 2.0 * t)
}

#[inline]
fn lerp_color(a: Color, b: Color, t: f32) -> Color {
	Color {
		r: a.r + (b.r - a.r) * t,
		g: a.g + (b.g - a.g) * t,
		b: a.b + (b.b - a.b) * t,
		a: a.a + (b.a - a.a) * t,
	}
}

fn snow_line(temperature: f32) -> f32 {
	640.0 + temperature * 260.0
}

fn surface_color(
	ground: Color,
	slope01: f32,
	height: f32,
	wetness: f32,
	snow_line_m: f32,
	roadness: f32,
) -> Color {
	let rock = color_rgb(0.35, 0.34, 0.33);
	let snow = color_rgb(0.86, 0.88, 0.92);
	let river_mud = color_rgb(0.34, 0.29, 0.21);
	let road_dirt = color_rgb(0.47, 0.37, 0.24);
	let rock_mix = smoothstep(0.42, 0.78, slope01);
	let mut color = lerp_color(ground, rock, rock_mix);
	if height > snow_line_m {
		let snow_mix =
			smoothstep(snow_line_m, snow_line_m + 130.0, height) * (1.0 - rock_mix * 0.6);
		color = lerp_color(color, snow, snow_mix);
	}
	if roadness > 0.0 {
		color = lerp_color(color, road_dirt, roadness.clamp(0.0, 1.0));
	}
	if wetness > 0.0 {
		color = lerp_color(color, river_mud, wetness.clamp(0.0, 1.0) * 0.85);
	}
	color
}

#[inline]
fn sample(
	values: &[f32],
	dims_x: i32,
	dims_y: i32,
	dims_z: i32,
	ix: i32,
	iy: i32,
	iz: i32,
) -> f32 {
	let ix = ix.clamp(0, dims_x - 1);
	let iy = iy.clamp(0, dims_y - 1);
	let iz = iz.clamp(0, dims_z - 1);
	values[((iz * dims_y + iy) * dims_x + ix) as usize]
}

fn gradient(
	values: &[f32],
	dims_x: i32,
	dims_y: i32,
	dims_z: i32,
	cx: i32,
	cy: i32,
	cz: i32,
) -> Vector3 {
	let x0 = (cx - 1).max(0);
	let x1 = (cx + 2).min(dims_x - 1);
	let y0 = (cy - 1).max(0);
	let y1 = (cy + 2).min(dims_y - 1);
	let z0 = (cz - 1).max(0);
	let z1 = (cz + 2).min(dims_z - 1);
	let gx = sample(values, dims_x, dims_y, dims_z, x1, cy, cz)
		- sample(values, dims_x, dims_y, dims_z, x0, cy, cz);
	let gy = sample(values, dims_x, dims_y, dims_z, cx, y1, cz)
		- sample(values, dims_x, dims_y, dims_z, cx, y0, cz);
	let gz = sample(values, dims_x, dims_y, dims_z, cx, cy, z1)
		- sample(values, dims_x, dims_y, dims_z, cx, cy, z0);
	let g = Vector3::new(-gx, -gy, -gz);
	if g.length_squared() > 0.000001 {
		g.normalized()
	} else {
		Vector3::UP
	}
}

#[inline]
fn cell_index(cells_x: i32, cells_y: i32, cx: i32, cy: i32, cz: i32) -> usize {
	((cz * cells_y + cy) * cells_x + cx) as usize
}

fn cell_vertex_at(
	cell_vertex: &[i32],
	cells_x: i32,
	cells_y: i32,
	cells_z: i32,
	c: [i32; 3],
) -> i32 {
	if c[0] < 0 || c[1] < 0 || c[2] < 0 || c[0] >= cells_x || c[1] >= cells_y || c[2] >= cells_z
	{
		return -1;
	}
	cell_vertex[cell_index(cells_x, cells_y, c[0], c[1], c[2])]
}

fn emit_quad(
	indices: &mut Vec<i32>,
	cell_vertex: &[i32],
	cells_x: i32,
	cells_y: i32,
	cells_z: i32,
	c0: [i32; 3],
	c1: [i32; 3],
	c2: [i32; 3],
	c3: [i32; 3],
	flip: bool,
) {
	let v0 = cell_vertex_at(cell_vertex, cells_x, cells_y, cells_z, c0);
	let v1 = cell_vertex_at(cell_vertex, cells_x, cells_y, cells_z, c1);
	let v2 = cell_vertex_at(cell_vertex, cells_x, cells_y, cells_z, c2);
	let v3 = cell_vertex_at(cell_vertex, cells_x, cells_y, cells_z, c3);
	if v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0 {
		return;
	}
	if flip {
		indices.extend_from_slice(&[v0, v2, v1, v0, v3, v2]);
	} else {
		indices.extend_from_slice(&[v0, v1, v2, v0, v2, v3]);
	}
}

pub fn build(
	values: PackedFloat32Array,
	ground_color: PackedColorArray,
	wetness: PackedFloat32Array,
	corridor_mask: PackedFloat32Array,
	temperature: PackedFloat32Array,
	roadness: PackedFloat32Array,
	dims_x: i32,
	dims_y: i32,
	dims_z: i32,
	voxel: f32,
	local_origin: Vector3,
	want_collision: bool,
	want_skirts: bool,
) -> Dictionary<Variant, Variant> {
	let values = values.to_vec();
	let cells_x = dims_x - 1;
	let cells_y = dims_y - 1;
	let cells_z = dims_z - 1;
	let cell_count = (cells_x * cells_y * cells_z) as usize;
	let mut cell_vertex = vec![-1i32; cell_count];

	let mut vertices: Vec<Vector3> = Vec::new();
	let mut normals: Vec<Vector3> = Vec::new();
	let mut colors: Vec<Color> = Vec::new();
	let mut uvs: Vec<Vector2> = Vec::new();
	let mut min_v = Vector3::new(f32::INFINITY, f32::INFINITY, f32::INFINITY);
	let mut max_v = Vector3::new(f32::NEG_INFINITY, f32::NEG_INFINITY, f32::NEG_INFINITY);

	for cz in 0..cells_z {
		for cy in 0..cells_y {
			for cx in 0..cells_x {
				let mut corner = [0.0f32; 8];
				let mut negative = 0;
				for c in 0..8 {
					let o = CORNER_OFFSET[c];
					let v = sample(
						&values,
						dims_x,
						dims_y,
						dims_z,
						cx + o[0],
						cy + o[1],
						cz + o[2],
					);
					corner[c] = v;
					if v < 0.0 {
						negative += 1;
					}
				}
				if negative == 0 || negative == 8 {
					continue;
				}

				let mut sum = Vector3::ZERO;
				let mut crossings = 0;
				for e in 0..12 {
					let pair = EDGE_CORNERS[e];
					let a = corner[pair[0]];
					let b = corner[pair[1]];
					if (a < 0.0) == (b < 0.0) {
						continue;
					}
					let t = a / (a - b);
					let pa = CORNER_OFFSET[pair[0]];
					let pb = CORNER_OFFSET[pair[1]];
					sum += Vector3::new(pa[0] as f32, pa[1] as f32, pa[2] as f32)
						+ (Vector3::new(pb[0] as f32, pb[1] as f32, pb[2] as f32)
							- Vector3::new(pa[0] as f32, pa[1] as f32, pa[2] as f32))
							* t;
					crossings += 1;
				}
				if crossings == 0 {
					continue;
				}

				let local = sum / crossings as f32;
				let position = local_origin
					+ (Vector3::new(cx as f32, cy as f32, cz as f32) + local) * voxel;
				let normal = gradient(&values, dims_x, dims_y, dims_z, cx, cy, cz);
				let col_ix = cx.min(dims_x - 1);
				let col_iz = cz.min(dims_z - 1);
				let column = (col_iz * dims_x + col_ix) as usize;
				let slope01 = (1.0 - normal.y).clamp(0.0, 1.0);
				let ground = if column < ground_color.len() {
					ground_color.get(column as usize).unwrap_or(color_rgb(0.36, 0.47, 0.22))
				} else {
					color_rgb(0.36, 0.47, 0.22)
				};
				let wet = if column < wetness.len() {
					wetness[column]
				} else {
					0.0
				};
				let temp = if column < temperature.len() {
					temperature[column]
				} else {
					0.5
				};
				let road = if column < roadness.len() {
					roadness[column]
				} else {
					0.0
				};
				let mask = if column < corridor_mask.len() {
					corridor_mask[column]
				} else {
					1.0
				};
				let color = surface_color(
					ground,
					slope01,
					position.y,
					wet,
					snow_line(temp),
					road,
				);

				let idx = vertices.len() as i32;
				cell_vertex[cell_index(cells_x, cells_y, cx, cy, cz)] = idx;
				vertices.push(position);
				normals.push(normal);
				colors.push(color);
				uvs.push(Vector2::new(mask, wet));
				min_v = Vector3::new(
					min_v.x.min(position.x),
					min_v.y.min(position.y),
					min_v.z.min(position.z),
				);
				max_v = Vector3::new(
					max_v.x.max(position.x),
					max_v.y.max(position.y),
					max_v.z.max(position.z),
				);
			}
		}
	}

	let mut out: Dictionary<Variant, Variant> = Dictionary::new();
	if vertices.is_empty() {
		out.set("vertices", &PackedVector3Array::new());
		out.set("normals", &PackedVector3Array::new());
		out.set("colors", &PackedColorArray::new());
		out.set("uvs", &PackedVector2Array::new());
		out.set("indices", &PackedInt32Array::new());
		out.set("collision_faces", &PackedVector3Array::new());
		out.set("surface_triangles", 0i32);
		out.set("aabb_position", Vector3::ZERO);
		out.set("aabb_size", Vector3::ZERO);
		return out;
	}

	let mut indices: Vec<i32> = Vec::new();
	for iz in 1..(dims_z - 1) {
		for iy in 1..(dims_y - 1) {
			for ix in 1..(dims_x - 1) {
				let here = sample(&values, dims_x, dims_y, dims_z, ix, iy, iz);
				let solid_here = here >= 0.0;

				if ix + 1 < dims_x {
					let vx = sample(&values, dims_x, dims_y, dims_z, ix + 1, iy, iz);
					if solid_here != (vx >= 0.0) {
						emit_quad(
							&mut indices,
							&cell_vertex,
							cells_x,
							cells_y,
							cells_z,
							[ix, iy - 1, iz - 1],
							[ix, iy, iz - 1],
							[ix, iy, iz],
							[ix, iy - 1, iz],
							solid_here,
						);
					}
				}
				if iy + 1 < dims_y {
					let vy = sample(&values, dims_x, dims_y, dims_z, ix, iy + 1, iz);
					if solid_here != (vy >= 0.0) {
						emit_quad(
							&mut indices,
							&cell_vertex,
							cells_x,
							cells_y,
							cells_z,
							[ix - 1, iy, iz - 1],
							[ix - 1, iy, iz],
							[ix, iy, iz],
							[ix, iy, iz - 1],
							solid_here,
						);
					}
				}
				if iz + 1 < dims_z {
					let vz = sample(&values, dims_x, dims_y, dims_z, ix, iy, iz + 1);
					if solid_here != (vz >= 0.0) {
						emit_quad(
							&mut indices,
							&cell_vertex,
							cells_x,
							cells_y,
							cells_z,
							[ix - 1, iy - 1, iz],
							[ix, iy - 1, iz],
							[ix, iy, iz],
							[ix - 1, iy, iz],
							solid_here,
						);
					}
				}
			}
		}
	}

	let surface_triangles = (indices.len() / 3) as i32;

	if want_skirts {
		let depth = voxel * SKIRT_DEPTH_FACTOR;
		let borders = [(0i32, 1i32), (0, cells_x - 1), (2, 1), (2, cells_z - 1)];
		for (axis, fixed) in borders {
			let tangent_count = if axis == 0 { cells_z } else { cells_x };
			for cy in 0..cells_y {
				for t in 1..(tangent_count - 1) {
					let a = if axis == 0 {
						[fixed, cy, t]
					} else {
						[t, cy, fixed]
					};
					let b = if axis == 0 {
						[fixed, cy, t + 1]
					} else {
						[t + 1, cy, fixed]
					};
					let va = cell_vertex_at(&cell_vertex, cells_x, cells_y, cells_z, a);
					let vb = cell_vertex_at(&cell_vertex, cells_x, cells_y, cells_z, b);
					if va < 0 || vb < 0 {
						continue;
					}
					let pa = vertices[va as usize];
					let pb = vertices[vb as usize];
					let na = normals[va as usize];
					let nb = normals[vb as usize];
					let ca = colors[va as usize];
					let cb = colors[vb as usize];
					let ua = uvs[va as usize];
					let ub = uvs[vb as usize];
					let base = vertices.len() as i32;
					vertices.extend_from_slice(&[
						pa,
						pb,
						pb - Vector3::new(0.0, depth, 0.0),
						pa - Vector3::new(0.0, depth, 0.0),
					]);
					normals.extend_from_slice(&[na, nb, nb, na]);
					colors.extend_from_slice(&[ca, cb, cb, ca]);
					uvs.extend_from_slice(&[ua, ub, ub, ua]);
					indices.extend_from_slice(&[
						base,
						base + 1,
						base + 2,
						base,
						base + 2,
						base + 3,
						base,
						base + 2,
						base + 1,
						base,
						base + 3,
						base + 2,
					]);
				}
			}
		}
	}

	let collision = if want_collision {
		let mut faces = Vec::with_capacity(indices.len());
		for &i in &indices {
			faces.push(vertices[i as usize]);
		}
		PackedVector3Array::from(faces)
	} else {
		PackedVector3Array::new()
	};

	out.set("vertices", &PackedVector3Array::from(vertices));
	out.set("normals", &PackedVector3Array::from(normals));
	out.set("colors", &PackedColorArray::from(colors));
	out.set("uvs", &PackedVector2Array::from(uvs));
	out.set("indices", &PackedInt32Array::from(indices));
	out.set("collision_faces", &collision);
	out.set("surface_triangles", surface_triangles);
	out.set("aabb_position", min_v);
	out.set("aabb_size", max_v - min_v);
	out
}
