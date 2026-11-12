# Texture Quality (Godot 3.x, GLES3)

Bakes several resolution tiers from each imported image, starts with the cheapest tier, and swaps
tiers at runtime using a quality level and a VRAM budget. Materials keep referencing the original
`.png` / `.jpg`; no material changes are needed.

## Setup
1. Copy `addons/texture_quality` into your project.
2. Project > Project Settings > Plugins > enable **Texture Quality**.

New images are then imported with the Texture Quality importer automatically. Images that were
already imported before the plugin was enabled are converted with
**Project > Tools > Texture Quality: Convert All Textures**. To run that automatically when the editor
starts, set `texture_quality/auto_convert_existing` to true (off by default).

## Import options
Select an imported image and use the Import dock. The presets set the colour-space handling:

- **Auto** detects normal maps and colour textures from the file name.
- **Color (sRGB)** is for albedo / diffuse / emissive textures.
- **Normal Map** compresses with normal-map settings.
- **Data (Linear)** is for roughness / metallic / mask textures.

The other options control the tier sizes, S3TC compression, repeat / filter / mipmaps /
anisotropic filtering, and the priority used by the VRAM budget solver. When converting an
existing texture, the plugin preserves repeat, filter, mipmaps, anisotropy, size limit, colour
space and uncompressed mode from the built-in Texture importer.

## Runtime settings
The **Texture Quality** menu in the 3D editor toolbar sets the quality level and VRAM budget. The
same values are written to Project Settings and read by the `TextureQuality` autoload:

- `texture_quality/quality`: tier index, `0` = highest
- `texture_quality/vram_budget_mb`: VRAM budget in MB, `0` = unlimited
- `texture_quality/max_swaps_per_frame`: GPU uploads per frame

## Distance LOD (v2.3)
Textures swap tiers by how far the camera is from the meshes that use them. Set the two distances in
**Project Settings > General > Texture Quality**:

- `texture_quality/near_distance` (default 5): at this distance or closer a texture uses its best tier.
- `texture_quality/far_distance` (default 60): at this distance or farther it uses its smallest tier.
- In between the tiers step down evenly. `texture_quality/distance_lod` turns the feature off.
- `texture_quality/lod_nodes_per_frame` (default 128): how many meshes are measured per frame.

How it works: the autoload tracks every `MeshInstance` and `Sprite3D`, finds the Texture Quality textures
in their materials (all SpatialMaterial slots, ShaderMaterial parameters, `next_pass`), and measures the
distance from the current camera to each node's bounding box. A texture used by several meshes follows
the nearest one. The global quality level stays the ceiling (LOD never gives a better tier than it allows)
and the VRAM budget still applies on top. A texture has to move a bit past the halfway point between two
tiers before it switches, so it does not flicker at a boundary.

**Excluding nodes (player, held weapon, ...):** select the node and tick **Ignore distance LOD (Texture
Quality)** at the top of the Inspector. That is the same as adding the node to the group
`texture_quality_ignore` (Node dock > Groups tab). That node and everything under it is left
out of distance LOD: its textures always keep the best tier the quality level allows, even when the
same texture is also used by meshes that are far away. From a script:
`TextureQuality.exclude_from_lod($Player)`, or `exclude_from_lod($Player, false)` to undo it.

Not covered: textures that no tracked node uses (UI, 2D sprites, particles, CSG, GridMap, terrain) use the
global quality level. Only the root viewport's current camera is used. Scripts can call
`TextureQuality.set_distance_range(near, far)`, `set_distance_lod_enabled(bool)` and
`save_distance_range(near, far)`.

## Notes
- Requires GLES3 because tiers use S3TC compression.
- New images are baked as soon as they are added to the project. Godot first imports a new png with its
  built-in Texture importer; the plugin notices that, switches the file to Texture Quality and reimports
  it a moment later (no Import dock, no restart prompt). The Output panel prints
  `Texture Quality: baking N new texture(s)...`. Turn this off with `texture_quality/convert_new_textures`,
  or pick another importer in the Import dock to opt out per file.
- Files under `res://addons/` and files using other custom importers are never converted
  automatically.
- The built-in importer's old `.stex` files may stay in `.import/` after conversion. They are no
  longer referenced and can be deleted.
