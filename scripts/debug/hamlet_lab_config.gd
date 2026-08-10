class_name HamletLabConfig
extends RefCounted
## Knobs for the evolutionary marketplace hamlet lab.


var seed: int = 1
var tier: int = 0

## Geometric-mean marketplace semi-axis (oriented ellipse base).
var market_radius: float = 4.0
## Ellipse aspect = major/minor; sampled in [min, max] each plan.
var market_aspect_min: float = 1.45
var market_aspect_max: float = 2.85
## Fractional radial jitter vs local ellipse radius (0–~0.9). Strong by default.
var market_radius_jitter: float = 0.62
## Fractional angular jitter vs half-sector (0–~0.95); keeps vertex order.
var market_angle_jitter: float = 0.88
## Clear gap from market rim to house front wall.
var market_front_gap: float = 2.5
## How far beyond the first ring settlers may push (second-row pressure).
var max_settle_radius: float = 55.0

var dwelling_min: int = 6
var dwelling_max: int = 15

## Soft alley dilation stamped into occupancy (metres).
var alley: float = 0.6
var occupancy_cell: float = 0.35
## Candidate poses evaluated per settler.
var candidates_per_settler: int = 80
## Softmax temperature: lower = greedier toward best plot.
var select_temperature: float = 0.18
## Weight: closer door-to-market is better.
var weight_market: float = 2.2
## Slight score bump when a candidate literally shares a wall (non-door sides).
var wall_share_boost: float = 0.12
## Small random noise on fitness (partially random choice among near-best).
var fitness_noise: float = 0.08

var show_occupancy: bool = false

## Civic ids placed once per settlement when tier allows (mirrors production).
const CIVIC_BY_TIER: Array = [
	[&"Well"],
	[&"Well"],
	[&"Well", &"Inn", &"Blacksmith", &"Sawmill", &"Stable", &"Gazebo"],
	[&"Well", &"Inn", &"Blacksmith", &"Mill", &"Sawmill", &"Stable", &"Bell_Tower", &"Gazebo"],
]


func market_side_count() -> int:
	return tier_market_sides(tier)


static func tier_market_sides(t: int) -> int:
	## Tier level is 1-lowest (hamlet) … 4 (port); sides = level * 6.
	return (clampi(t, 0, 3) + 1) * 6


static func tier_market_radius(t: int) -> float:
	## Canonical mean semi-axis for a marketplace of the given tier.
	match clampi(t, 0, 3):
		0:
			return 8.0
		1:
			return 12.0
		2:
			return 18.0
		_:
			return 28.0


func apply_tier_defaults(t: int) -> void:
	tier = clampi(t, 0, 3)
	match tier:
		0:
			# Hamlet — markets sized for ~9–14 m house depths
			dwelling_min = 6
			dwelling_max = 15
			market_radius = 8.0
			max_settle_radius = 80.0
			candidates_per_settler = 80
			occupancy_cell = 0.4
		1:
			# Village
			dwelling_min = 20
			dwelling_max = 80
			market_radius = 12.0
			max_settle_radius = 160.0
			candidates_per_settler = 100
			occupancy_cell = 0.45
		2:
			# Town
			dwelling_min = 100
			dwelling_max = 400
			market_radius = 18.0
			max_settle_radius = 320.0
			candidates_per_settler = 80
			occupancy_cell = 0.6
		3:
			# Port / city
			dwelling_min = 500
			dwelling_max = 2000
			market_radius = 28.0
			max_settle_radius = 600.0
			candidates_per_settler = 60
			occupancy_cell = 0.8
