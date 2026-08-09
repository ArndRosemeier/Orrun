class_name AtlasPack
extends RefCounted
## Bit packing and elevation mapping for one atlas climate cell.


static func pack(elevation: int, humidity: int, biome: int, relief: int, population: int) -> int:
	return (
		(clampi(elevation, 0, 255))
		| (clampi(humidity, 0, 255) << 8)
		| (clampi(biome, 0, 63) << 16)
		| (clampi(relief, 0, 63) << 22)
		| (clampi(population, 0, 15) << 28)
	)


static func elevation(cell: int) -> int:
	return cell & 0xFF


static func humidity(cell: int) -> int:
	return (cell >> 8) & 0xFF


static func biome(cell: int) -> int:
	return (cell >> 16) & 0x3F


static func relief(cell: int) -> int:
	return (cell >> 22) & 0x3F


static func population(cell: int) -> int:
	return (cell >> 28) & 0xF


## Quantized metres for an elevation code. Endpoints are locked by tests.
static func elevation_to_metres(code: int) -> int:
	var c: int = clampi(code, 0, 255)
	if c <= 32:
		return int(lerpf(-80.0, 0.0, float(c) / 32.0))
	if c <= 40:
		return int(lerpf(0.0, 12.0, float(c - 33) / 7.0))
	if c <= 120:
		return int(lerpf(12.0, 180.0, float(c - 41) / 79.0))
	if c <= 180:
		return int(lerpf(180.0, 420.0, float(c - 121) / 59.0))
	if c <= 220:
		return int(lerpf(420.0, 720.0, float(c - 181) / 39.0))
	return int(lerpf(720.0, 980.0, float(c - 221) / 34.0))


static func metres_to_elevation(metres: int) -> int:
	var m: float = float(metres)
	if m <= 0.0:
		return clampi(int((m + 80.0) / 80.0 * 32.0), 0, 32)
	if m <= 12.0:
		return 33 + int(m / 12.0 * 7.0)
	if m <= 180.0:
		return 41 + int((m - 12.0) / 168.0 * 79.0)
	if m <= 420.0:
		return 121 + int((m - 180.0) / 240.0 * 59.0)
	if m <= 720.0:
		return 181 + int((m - 420.0) / 300.0 * 39.0)
	return clampi(221 + int((m - 720.0) / 260.0 * 34.0), 221, 255)
