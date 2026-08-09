class_name AtlasPack
extends RefCounted
## Bit packing and elevation mapping for one atlas climate cell.
##
## Land height uses an exponential decode so 8-bit codes keep fine steps near
## sea level (coasts, river mouths) and still reach Alps-scale peaks. Sea shelf
## stays linear. See docs/CONTINENT_ATLAS.md §4.3.

## Sea shelf: code 0 → SEA_FLOOR_M, code 32 → 0.
const SEA_FLOOR_M: float = -80.0
const SEA_CODE_MAX: int = 32
## Coastal lowland band (linear): code 33 → 0 m, code 40 → COAST_MAX_M.
const COAST_CODE_MIN: int = 33
const COAST_CODE_MAX: int = 40
const COAST_MAX_M: float = 20.0
## Exponential land band: code 41 → COAST_MAX_M, code 255 → PEAK_MAX_M.
const LAND_CODE_MIN: int = 41
const LAND_CODE_MAX: int = 255
const PEAK_MAX_M: float = 4000.0
## Curve steepness. Higher → more of the code range stays lowland/hill, with
## metres accelerating into the mountain/peak codes.
const LAND_EXP_K: float = 4.0


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
	if c <= SEA_CODE_MAX:
		return int(lerpf(SEA_FLOOR_M, 0.0, float(c) / float(SEA_CODE_MAX)))
	if c <= COAST_CODE_MAX:
		var u: float = float(c - COAST_CODE_MIN) / float(COAST_CODE_MAX - COAST_CODE_MIN)
		return int(lerpf(0.0, COAST_MAX_M, u))
	var t: float = float(c - LAND_CODE_MIN) / float(LAND_CODE_MAX - LAND_CODE_MIN)
	return int(_land_exp_metres(t))


static func metres_to_elevation(metres: int) -> int:
	var m: float = float(metres)
	if m <= 0.0:
		return clampi(int((m - SEA_FLOOR_M) / (0.0 - SEA_FLOOR_M) * float(SEA_CODE_MAX)), 0, SEA_CODE_MAX)
	if m <= COAST_MAX_M:
		var u: float = m / COAST_MAX_M
		return COAST_CODE_MIN + int(u * float(COAST_CODE_MAX - COAST_CODE_MIN))
	var span: float = PEAK_MAX_M - COAST_MAX_M
	var ratio: float = clampf((m - COAST_MAX_M) / span, 0.0, 1.0)
	# Invert h = h0 + span * (e^{kt}-1)/(e^k-1).
	var ek: float = exp(LAND_EXP_K)
	var inside: float = 1.0 + ratio * (ek - 1.0)
	var t: float = log(inside) / LAND_EXP_K
	return clampi(
		LAND_CODE_MIN + int(t * float(LAND_CODE_MAX - LAND_CODE_MIN) + 0.5),
		LAND_CODE_MIN,
		LAND_CODE_MAX
	)


static func _land_exp_metres(t01: float) -> float:
	var t: float = clampf(t01, 0.0, 1.0)
	var ek: float = exp(LAND_EXP_K)
	var shaped: float = (exp(LAND_EXP_K * t) - 1.0) / (ek - 1.0)
	return COAST_MAX_M + (PEAK_MAX_M - COAST_MAX_M) * shaped
