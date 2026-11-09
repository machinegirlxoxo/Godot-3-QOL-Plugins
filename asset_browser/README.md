# AssetBrowser (Godot 3.x editor plugin)

One main-screen tab ("AssetBrowser") with a sub-tab per marketplace.

## Install
1. Disable and delete the old `addons/polyhaven_browser` folder (its code now lives in this plugin).
2. Copy `addons/asset_browser` into your project's `addons/` folder.
3. Project > Project Settings > Plugins > enable **AssetBrowser**.

## Poly Haven tab
Same as before: HDRIs, textures and models, pick resolution/format, saved under `res://PolyHaven`.

## Fab / Megascans tab
Fab has no public API, so the plugin does not log in to Fab or scrape it. It uses the
launcher's own export feature ("Custom (socket port)") and receives the asset from there:

1. Open the **Epic Games Launcher > Fab** tab, click the gear icon and set
   **Export Target = Custom (socket port)**, port = the one shown in this tab (default 24981).
2. Open an asset in your Fab library (Megascans included), pick a format (glTF or FBX are best), press **Export**.
3. The plugin copies the textures and meshes into `res://Fab/<Surfaces|Assets|Plants|Atlases>/<Name>/`,
   builds a material (`<Name>.tres`) and, for meshes, a ready-to-use scene (`<Name>.scn`).

Details
- Packed textures (e.g. AO/Roughness/Displacement in one image) are wired by channel.
- Plants with an opacity map get a small alpha-scissor shader material (Godot 3 has no separate opacity slot).
- "Mesh LOD" picks that LOD when the launcher exports one file per LOD.
- "Import from folder..." imports an asset folder you already have on disk (disk export, old Bridge downloads).
- The server only listens on 127.0.0.1, accepts only JSON, and only copies image/mesh files into `res://`.

## Troubleshooting
- "Could not listen": another program (e.g. a Megascans Link plugin) uses that port. Change it here and in the launcher.
- Nothing arrives: check the launcher's port matches, and that the tab says "Listening". If your launcher
  resolves `localhost` to IPv6 only, tell me and I'll add an address option.
- Assets are imported as the launcher describes them; if a layout is unusual, use "Import from folder...".

## Licensing
Megascans from Fab fall under the Fab license, not CC0. Don't commit them to public repos.
Poly Haven assets are CC0 (the plugin credits Poly Haven, as they request).

## Adding another marketplace
Write a Control script with `var editor` and `func on_shown()`, then add a line to `PROVIDERS` in `shell.gd`.
