//! FastNoiseLite helpers matching Orrun's Godot `NoiseSet` / atlas setup.
//!
//! Godot `TYPE_SIMPLEX_SMOOTH` == Auburn OpenSimplex2S.

use fastnoise_lite::{FastNoiseLite, FractalType, NoiseType};

pub struct Noise2D {
	inner: FastNoiseLite,
}

impl Noise2D {
	pub fn fbm(seed: i32, frequency: f32, octaves: i32, gain: f32, lacunarity: f32) -> Self {
		let mut n = FastNoiseLite::with_seed(seed);
		n.set_noise_type(Some(NoiseType::OpenSimplex2S));
		n.set_fractal_type(Some(FractalType::FBm));
		n.set_frequency(Some(frequency));
		n.set_fractal_octaves(Some(octaves));
		n.set_fractal_gain(Some(gain));
		n.set_fractal_lacunarity(Some(lacunarity));
		Self { inner: n }
	}

	pub fn ridged(seed: i32, frequency: f32, octaves: i32, gain: f32, lacunarity: f32) -> Self {
		let mut n = FastNoiseLite::with_seed(seed);
		n.set_noise_type(Some(NoiseType::OpenSimplex2S));
		n.set_fractal_type(Some(FractalType::Ridged));
		n.set_frequency(Some(frequency));
		n.set_fractal_octaves(Some(octaves));
		n.set_fractal_gain(Some(gain));
		n.set_fractal_lacunarity(Some(lacunarity));
		Self { inner: n }
	}

	/// Atlas-style constructor: Godot defaults for gain/lacunarity.
	pub fn atlas_fbm(seed: i32, frequency: f32, octaves: i32) -> Self {
		Self::fbm(seed, frequency, octaves, 0.5, 2.0)
	}

	pub fn atlas_ridged(seed: i32, frequency: f32, octaves: i32) -> Self {
		Self::ridged(seed, frequency, octaves, 0.5, 2.0)
	}

	/// NoiseSet-style: frequency = 1 / period_metres.
	pub fn from_period_fbm(
		seed: i32,
		period: f32,
		octaves: i32,
		gain: f32,
		lacunarity: f32,
	) -> Self {
		Self::fbm(seed, 1.0 / period, octaves, gain, lacunarity)
	}

	pub fn from_period_ridged(
		seed: i32,
		period: f32,
		octaves: i32,
		gain: f32,
		lacunarity: f32,
	) -> Self {
		Self::ridged(seed, 1.0 / period, octaves, gain, lacunarity)
	}

	#[inline]
	pub fn get(&self, x: f32, y: f32) -> f32 {
		self.inner.get_noise_2d(x, y)
	}
}
