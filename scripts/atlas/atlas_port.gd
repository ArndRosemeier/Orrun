class_name AtlasPort
extends RefCounted
## Edge port on a shared cell boundary.


var id: int = 0
var t: float = 0.5
var kind: int = AtlasFeatures.Kind.RIVER
var feature_class: int = 1
var flow_sign: int = 1
## Quantized metres at the crossing (water surface or road grade).
var surface_z: int = 0
var feature_id: int = 0
