class_name WaterSurface
extends RefCounted
## Builds the visible water for one chunk.
##
## There is no global water plane. Every column of the density field already
## carries the height of whichever river or lake reaches it ([code]water_top[/code])
## and the height of the ground there ([code]surface_z[/code]); water is simply
## the sheet between them. Reading it back off the same field the terrain was
## meshed from is what keeps the two glued together: the shoreline lands exactly
## where the ground crosses the water, at the resolution of the mesh, instead of
## on a macro cell boundary 32 m away.

## A cell with one corner under water still emits a full quad. The dry corners
## are covered by ground that is higher than the sheet, so the terrain draws the
## shoreline and the overhang is never seen. Must equal
## [constant DensityField.MIN_VISIBLE_WATER_CLEARANCE]: that is the contract the
## density field enforces, and this is the cull the mesh applies.
const WET_EPSILON: float = 0.02


class WaterData extends RefCounted:
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	## UV.x runs across the sheet, UV.y along it, in metres.
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	func is_empty() -> bool:
		return indices.is_empty()


static func build(field: DensityField.Field, chunk_origin: Vector2) -> WaterData:
	var data: WaterData = WaterData.new()
	if not field.has_water:
		return data

	var samples: int = field.dims.x
	var voxel: float = field.voxel
	# Sample 0 is one voxel outside the chunk and sample samples-1 one voxel
	# past it, so cells 1..samples-2 tile the chunk exactly. Stopping a cell
	# short leaves a voxel-wide dry seam along every chunk border, which reads
	# as a grid of cracks drawn across every lake.
	var last: int = samples - 1

	var vertex_at: PackedInt32Array = PackedInt32Array()
	vertex_at.resize(samples * samples)
	for i in vertex_at.size():
		vertex_at[i] = -1

	for iz in range(1, last):
		for ix in range(1, last):
			var c00: int = iz * samples + ix
			var c10: int = c00 + 1
			var c01: int = c00 + samples
			var c11: int = c01 + 1

			var top: float = -INF
			top = maxf(top, _wet_top(field, c00))
			top = maxf(top, _wet_top(field, c10))
			top = maxf(top, _wet_top(field, c01))
			top = maxf(top, _wet_top(field, c11))
			if top == -INF:
				continue

			var v00: int = _emit_vertex(data, field, vertex_at, c00, ix, iz, top, voxel)
			var v10: int = _emit_vertex(data, field, vertex_at, c10, ix + 1, iz, top, voxel)
			var v11: int = _emit_vertex(
				data, field, vertex_at, c11, ix + 1, iz + 1, top, voxel
			)
			var v01: int = _emit_vertex(data, field, vertex_at, c01, ix, iz + 1, top, voxel)
			data.indices.append_array(PackedInt32Array([
				v00, v11, v10, v00, v01, v11
			]))

	return data


## The water height at a column, but only where the ground is actually below it.
static func _wet_top(field: DensityField.Field, column: int) -> float:
	var top: float = field.water_top[column]
	if top == -INF or field.surface_z[column] >= top - WET_EPSILON:
		return -INF
	return top


## Corners are shared between cells so the sheet has no cracks. A dry corner
## borrows the height of the cell that pulled it in, which keeps a river ribbon
## level across its own width instead of tilting into the bank.
static func _emit_vertex(
	data: WaterData,
	field: DensityField.Field,
	vertex_at: PackedInt32Array,
	column: int,
	ix: int,
	iz: int,
	fallback: float,
	voxel: float
) -> int:
	var existing: int = vertex_at[column]
	if existing >= 0:
		return existing

	var top: float = field.water_top[column]
	var clearance: float = 0.0
	if top == -INF:
		top = fallback
		# Dry corner pulled into a wet cell: give it a token depth so the shore
		# fade still has something to work with. The real clearance lives on
		# the wet corners.
		clearance = WET_EPSILON * 2.0
	else:
		clearance = maxf(top - field.surface_z[column], WET_EPSILON)
	var world: Vector3 = field.sample_world_position(ix, 0, iz)
	var local: Vector3 = Vector3(
		world.x - field.origin.x - voxel, top, world.z - field.origin.z - voxel
	)

	var index: int = data.vertices.size()
	data.vertices.append(local)
	data.normals.append(Vector3.UP)
	# UV.x is unused by the shader (ripples use world position). UV.y carries
	# the bed clearance authored by the density field so alpha does not depend
	# on whatever happens to sit in the scene depth buffer under the sheet.
	data.uvs.append(Vector2(world.x, clearance))
	vertex_at[column] = index
	return index
