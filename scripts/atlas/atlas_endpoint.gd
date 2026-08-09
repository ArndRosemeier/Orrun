class_name AtlasEndpoint
extends RefCounted
## One end of an in-cell river or road link.


var kind: int = AtlasFeatures.EndpointKind.EDGE_PORT
## For EDGE_PORT: packed edge key. For NODE: node id. For LAKE: lake id.
var ref_id: int = 0
## Port index on the edge, or 0 for terminals.
var port_id: int = 0
