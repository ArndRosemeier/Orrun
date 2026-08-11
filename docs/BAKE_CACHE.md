# Bake cache (disk)

Orrun persists expensive boot artifacts under `user://cache/` so a second launch
with the same seed/config can skip atlas generation, spawn-sector bake, and the
underfoot LOD0 remesh. Implementation: [`scripts/world/bake_cache.gd`](../scripts/world/bake_cache.gd).

## Artifacts

| Blob | Magic | Version constant | Path key | Typical size |
|------|-------|------------------|----------|--------------|
| Continent atlas | `ORAT` | `FORMAT_VERSION` | `config.content_hash()` | ~5–8 MB @ 256 km |
| Spawn / sector bake | `ORWS` | `FORMAT_VERSION` | `context.content_key()` | ~5–7 MB / sector |
| Underfoot LOD0 chunk | `ORCK` | `CHUNK_FORMAT_VERSION` | `BakeCache.chunk_key(context)` | ~0.3–1.5 MB / chunk |

Chunk warm ring is Chebyshev ≤1 (3×3). Farther LODs are not cached.

## Versioning (mandatory for agents)

**Never load a blob whose header does not match the current code.** On magic or
version mismatch the loader must miss (warn + regenerate). Do not silently
reinterpret old bytes. Do not add “best effort” migration unless explicitly
requested.

When you change a packed layout:

1. **Atlas or sector body fields / order / types** → bump `BakeCache.FORMAT_VERSION`.
2. **LOD0 chunk body** (mesh/water/props/bridge-id layout) → bump `BakeCache.CHUNK_FORMAT_VERSION` (independent of atlas/sector).
3. **What the atlas algorithm produces** → bump `ContinentAtlas.SCHEMA_VERSION` (also stored in the atlas header).
4. **World knobs that change sector/atlas content** → already covered by `WorldConfig.content_hash()` / `WorldContext.content_key()`; ensure new knobs are added to the hash if they affect baked data.
5. **Mesh / density knobs that do not change the sector bake** (LOD0 voxel, skirts, caves, props rings, overhang, …) → already covered by `WorldConfig.mesh_content_hash()`; add new knobs there if they change chunk meshes.

Old files may remain on disk; they are ignored when the header or path key differs.

## Header contract

Every file starts with:

```
magic: u32
format_version: u32
… identity fields (seed/size/schema or content_key or chunk_key + coords) …
body
```

Trailing bytes after a successful body read are treated as corrupt (error + miss).

## Fail-loud policy

Aligned with project rules: a wrong cache must not produce a wrong world. Prefer
regenerate with a clear `BakeCache: … mismatch; regenerating` warning over
asserting on every intentional knob change. Truncation / missing bridge ids /
size mismatches → error and miss.

## Related code

- Boot load/save: [`scripts/main.gd`](../scripts/main.gd) (`_bake_atlas`, `_load_or_bake_sector`)
- Chunk warm path: [`scripts/world/streamer.gd`](../scripts/world/streamer.gd) (`_enqueue_chunk_job`, `_maybe_save_warm_chunk`)
- Hashes: [`WorldConfig.content_hash`](../scripts/world/world_config.gd), [`mesh_content_hash`](../scripts/world/world_config.gd), [`WorldContext.content_key`](../scripts/world/world_context.gd)
- Tests: [`tools/tests/bake_cache_tests.gd`](../tools/tests/bake_cache_tests.gd)
