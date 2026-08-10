use godot::prelude::*;

mod atlas_landmask;
mod fields;
mod fill_window;
mod flood;
mod lakes;
mod mesh_extract;
mod noise;
mod road_astar;
mod volume;

struct OrrunGenExtension;

#[gdextension]
unsafe impl ExtensionLibrary for OrrunGenExtension {}

/// Native generation kernels for Orrun.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct OrrunGen {
	base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for OrrunGen {
	fn init(base: Base<RefCounted>) -> Self {
		Self { base }
	}
}

#[godot_api]
impl OrrunGen {
	#[func]
	fn priority_flood(
		&self,
		elevation: PackedFloat32Array,
		sink_mask: PackedByteArray,
		outflow_cells: PackedInt32Array,
		cells: i32,
		min_elevation: f32,
		max_elevation: f32,
		level_step: f32,
	) -> Dictionary<Variant, Variant> {
		flood::priority_flood(
			elevation,
			sink_mask,
			outflow_cells,
			cells,
			min_elevation,
			max_elevation,
			level_step,
		)
	}

	#[func]
	fn accumulate(
		&self,
		flow_order: PackedInt32Array,
		receiver: PackedInt32Array,
		moisture: PackedFloat32Array,
		inflow_boosts: PackedFloat32Array,
	) -> PackedFloat32Array {
		flood::accumulate(flow_order, receiver, moisture, inflow_boosts)
	}

	#[func]
	fn find_lakes(
		&self,
		elevation: PackedFloat32Array,
		filled: PackedFloat32Array,
		sink_mask: PackedByteArray,
		receiver: PackedInt32Array,
		accumulation: PackedFloat32Array,
		params: Dictionary<Variant, Variant>,
	) -> Dictionary<Variant, Variant> {
		let get_i = |key: &str| -> i32 { params.get_or_nil(key).to::<i32>() };
		let get_f = |key: &str| -> f32 { params.get_or_nil(key).to::<f32>() };
		lakes::find_lakes(
			elevation,
			filled,
			sink_mask,
			receiver,
			accumulation,
			lakes::LakeParams {
				cells: get_i("cells"),
				cell_size: get_f("cell_size"),
				origin_x: get_i("origin_x"),
				origin_z: get_i("origin_z"),
				local_min_x: get_i("local_min_x"),
				local_min_z: get_i("local_min_z"),
				local_max_x: get_i("local_max_x"),
				local_max_z: get_i("local_max_z"),
				lake_epsilon: get_f("lake_epsilon"),
				surface_tol: 0.02,
				local_lake_max_span: get_f("local_lake_max_span"),
				lake_min_cells: get_i("lake_min_cells"),
				lake_max_cells: get_i("lake_max_cells"),
				lake_min_depth: get_f("lake_min_depth"),
			},
		)
	}

	/// Macro sector window. `params` holds origin, sizes, tuning, and noise seeds.
	#[func]
	fn fill_window(
		&self,
		elevation_m: PackedFloat32Array,
		humidity01: PackedFloat32Array,
		relief01: PackedFloat32Array,
		water_flag: PackedFloat32Array,
		water_plane: PackedFloat32Array,
		rivers: PackedFloat32Array,
		river_bases: PackedInt32Array,
		params: Dictionary<Variant, Variant>,
	) -> Dictionary<Variant, Variant> {
		let get_i = |key: &str| -> i32 { params.get_or_nil(key).to::<i64>() as i32 };
		let get_f = |key: &str| -> f32 { params.get_or_nil(key).to::<f32>() };
		let settlement_pads = params
			.get_or_nil("settlement_pads")
			.try_to::<PackedFloat32Array>()
			.unwrap_or_default();
		fill_window::fill_window(
			elevation_m,
			humidity01,
			relief01,
			water_flag,
			water_plane,
			rivers,
			river_bases,
			fill_window::FillParams {
				origin_x: get_i("origin_x"),
				origin_z: get_i("origin_z"),
				cells: get_i("cells"),
				macro_cell_size: get_f("macro_cell_size"),
				atlas_size: get_i("atlas_size"),
				continent_span: get_f("continent_span"),
				max_valley_radius: get_f("max_valley_radius"),
				trunk_valley_radius: get_f("trunk_valley_radius"),
				trunk_valley_per_class: get_f("trunk_valley_per_class"),
				trunk_bank_rise: get_f("trunk_bank_rise"),
				swell_height: get_f("swell_height"),
				mountain_detail: get_f("mountain_detail"),
				mountain_octaves: get_i("mountain_octaves"),
				mountain_gain: get_f("mountain_gain"),
				mountain_sharpness: get_f("mountain_sharpness"),
				mountain_macro_contrast: get_f("mountain_macro_contrast"),
				warp_strength: get_f("warp_strength"),
				ocean_floor_margin: get_f("ocean_floor_margin"),
				inland_freeboard: get_f("inland_freeboard"),
				sea_surface_z: get_f("sea_surface_z"),
				relief_amp_plains: get_f("relief_amp_plains"),
				relief_amp_hills: get_f("relief_amp_hills"),
				relief_amp_mountains: get_f("relief_amp_mountains"),
				seed_swell: get_i("seed_swell"),
				seed_mountain: get_i("seed_mountain"),
				seed_warp_a: get_i("seed_warp_a"),
				seed_warp_b: get_i("seed_warp_b"),
				seed_moisture: get_i("seed_moisture"),
				seed_temperature: get_i("seed_temperature"),
				seed_coast: get_i("seed_coast"),
				swell_scale: get_f("swell_scale"),
				mountain_noise_scale: get_f("mountain_noise_scale"),
				warp_scale: get_f("warp_scale"),
				settlement_pads,
				settlement_detail_damp: get_f("settlement_detail_damp"),
				settlement_core_end: get_f("settlement_core_end"),
				settlement_pad_stride: get_i("settlement_pad_stride"),
			},
		)
	}

	/// Atlas landmask + elev/humidity/relief codes. Seeds from GDScript `_layer_seed`.
	/// Godot `hash()` values are truncated to i32 the same way FastNoiseLite.seed is.
	#[func]
	fn atlas_landmask(
		&self,
		params: Dictionary<Variant, Variant>,
	) -> Dictionary<Variant, Variant> {
		let get_i = |key: &str| -> i32 { params.get_or_nil(key).to::<i32>() };
		let get_seed = |key: &str| -> i32 { params.get_or_nil(key).to::<i64>() as i32 };
		atlas_landmask::build_landmask(atlas_landmask::LandmaskParams {
			size: get_i("size"),
			seed_continent: get_seed("seed_continent"),
			seed_coast_cut: get_seed("seed_coast_cut"),
			seed_peninsula: get_seed("seed_peninsula"),
			seed_mountain: get_seed("seed_mountain"),
			seed_moist: get_seed("seed_moist"),
			seed_relief: get_seed("seed_relief"),
			seed_warp: get_seed("seed_warp"),
			seed_warp2: get_seed("seed_warp2"),
		})
	}

	/// Atlas road pathfinding. `river_channel[i] != 0` marks cells with river links.
	#[func]
	fn road_astar(
		&self,
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
		road_astar::road_astar(
			cells,
			elev_code,
			river_adjacent,
			river_channel,
			size,
			start,
			goal,
			biome_ocean,
			biome_lake,
			biome_alpine,
		)
	}

	/// Surface-nets extract over a density volume. Column arrays are XZ-major.
	#[func]
	fn mesh_extract(
		&self,
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
		mesh_extract::build(
			values,
			ground_color,
			wetness,
			corridor_mask,
			temperature,
			roadness,
			dims_x,
			dims_y,
			dims_z,
			voxel,
			local_origin,
			want_collision,
			want_skirts,
		)
	}

	/// 3D density volume from column surfaces. Returns values + origin_y + samples_y.
	#[func]
	fn build_volume(
		&self,
		surface_z: PackedFloat32Array,
		corridor_mask: PackedFloat32Array,
		water_top: PackedFloat32Array,
		overhang_amp: PackedFloat32Array,
		params: Dictionary<Variant, Variant>,
	) -> Dictionary<Variant, Variant> {
		let get_i = |key: &str| -> i32 { params.get_or_nil(key).to::<i64>() as i32 };
		let get_f = |key: &str| -> f32 { params.get_or_nil(key).to::<f32>() };
		let get_b = |key: &str| -> bool { params.get_or_nil(key).to::<bool>() };
		volume::build_volume(
			surface_z,
			corridor_mask,
			water_top,
			overhang_amp,
			volume::VolumeParams {
				samples_h: get_i("samples_h"),
				voxel: get_f("voxel"),
				origin_x: get_f("origin_x"),
				origin_z: get_f("origin_z"),
				surface_band: get_f("surface_band"),
				vertical_margin: get_f("vertical_margin"),
				world_floor: get_f("world_floor"),
				world_ceiling: get_f("world_ceiling"),
				cave_enabled: get_b("cave_enabled"),
				cave_top_depth: get_f("cave_top_depth"),
				cave_bottom_depth: get_f("cave_bottom_depth"),
				cave_threshold: get_f("cave_threshold"),
				cave_water_clearance: get_f("cave_water_clearance"),
				seed_overhang: get_i("seed_overhang"),
				overhang_scale: get_f("overhang_scale"),
				seed_cave_a: get_i("seed_cave_a"),
				seed_cave_b: get_i("seed_cave_b"),
				cave_scale: get_f("cave_scale"),
			},
		)
	}

	#[func]
	fn version(&self) -> GString {
		GString::from("orrun_gen 0.3.0 (mesh+volume+fill+atlas+roads)")
	}
}
