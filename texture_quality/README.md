# Texture Quality (Godot 3.x, GLES3)

Bakes several resolution tiers from each imported image, starts with the cheapest tier, and swaps
tiers at runtime using a quality level and a VRAM budget. Materials keep referencing the original
`.png` / `.jpg`; no material changes are needed.

## Setup
1. Copy `addons/texture_quality` into your project.
2. Project > Project Settings > Plugins > enable **Texture Quality**.

New images are then imported with the Texture Quality importer automatically. Images that were
already imported before the plugin was enabled are converted in place the next time the editor
starts, without a restart prompt. You can run the conversion by hand at any time with
**Project > Tools > Texture Quality: Convert All Textures**.

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

## Notes
- Requires GLES3 because tiers use S3TC compression.
- To turn off automatic conversion of pre-existing textures, set
  `texture_quality/auto_convert_existing=false` in Project Settings. New imports still use the
  Texture Quality importer; pick another importer in the Import dock to opt out per file.
- Files under `res://addons/` and files using other custom importers are never converted
  automatically.
- The built-in importer's old `.stex` files may stay in `.import/` after conversion. They are no
  longer referenced and can be deleted.
