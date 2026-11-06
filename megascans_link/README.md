# Megascans Link (Godot 3.x)

Imports Quixel Megascans into the editor. Quixel has no public download API, so this plugin does
not log in or download anything itself: Quixel Bridge (or the Fab exporter) downloads, this
plugin receives and imports.

## Setup
1. Copy `addons/megascans_link` into your project, then Project > Project Settings > Plugins > enable "Megascans Link".
2. Open the new **Megascans** tab (next to 2D / 3D / Script) and press **Start listening**.
3. In Quixel Bridge: Export Settings > Export Target = **Custom Socket Export**, Socket Port = the port shown
   in the tab (default 24981), Mesh Format = **OBJ** (Godot 3 cannot import FBX).
4. Download an asset in Bridge and press Export. It shows up in the tab and is imported into `res://Megascans/`.

No Bridge? **Import folder...** takes any folder of downloaded Megascans/Fab files and matches the
maps by file name (Albedo, Normal, Roughness, Metalness, AO, Opacity, Displacement, Emission).

## What you get
- `Surfaces/`, `Models/`, `Plants/`, `Atlases/`, `Brushes/` folders, one per asset
- a material `.tres`: SpatialMaterial, or a small alpha-scissor ShaderMaterial when the asset has an opacity map
- a `.tscn` for 3D assets (highest-detail LOD only, material applied)

## Notes
- The listener binds to 127.0.0.1 only. Only texture and mesh file types are copied.
- Normal maps: Bridge exports OpenGL normals, which is what Godot expects. DirectX normals are ignored.
- Gloss maps are not converted to roughness. Choose roughness in Bridge's export settings.
- Licensing: assets from the old Bridge/Quixel library are under the Epic Content License (free use
  only in Unreal Engine). Assets from Fab are under the Fab Standard License. Check which one covers your copy.
