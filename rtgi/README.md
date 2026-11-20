# RTGI – ray-traced global illumination GDNative node (Godot 3.5, GLES3)

`RTGI` is a `Spatial` node. It builds a BVH of the scene on the CPU (multithreaded),
ray traces an irradiance probe grid (6-axis ambient cube per probe, with direct light + sky + infinite bounces via
probe feedback), temporally accumulates it, and uploads it as a half-float atlas texture that surface shaders sample.

Godot 3.5's GLES3 renderer has no hardware RT, so tracing runs on the CPU. It is amortized (a few hundred probes per frame)
and goes idle once the scene stops changing.

## Install
1. Build godot-cpp 3.5 and this library (below).
2. Copy this folder to `res://addons/rtgi/` (needs `bin/`, `shaders/`, and the `*.gd` / `plugin.cfg` files).
3. **Project → Project Settings → Plugins → RTGI → Enable.**
4. Select your **WorldEnvironment** node, open its **Environment** and scroll to the new **RTGI** section (right below SSAO).
   Tick **Enabled**. That's it: an `RTGI` node is created next to the WorldEnvironment with `bin/rtgi.gdns` already loaded
   as its script, and its probe grid is fitted to the level automatically. Untick to remove it. (Undo/redo works.)
   - **Fit Probe Grid To Scene** re-fits the grid after you change the level; **Select RTGI Node** opens all settings.
   - The RTGI node is saved with the scene, so it runs in the game without the plugin being active.

Manual alternative (no plugin): add a Spatial node and attach `res://addons/rtgi/bin/rtgi.gdns` as its script
(the class registers as a tool script, so it runs in the editor too).
`geometry_root` defaults to `..`, so the RTGI node should be a sibling of / parent over your level; size `bounds_size`
so the probe grid (centered on the node) covers the area.

By default (`auto_apply_shader`) every `SpatialMaterial` surface under `geometry_root` is swapped for a generated
ShaderMaterial (albedo, albedo texture, metallic, roughness, emission, uv1 copied) that receives the GI.
Originals are restored when the node leaves the tree. Transparent materials are skipped.
For custom shaders, copy the `rtgi_*` uniforms/functions from `shaders/rtgi_surface.shader`; any ShaderMaterial whose code
contains `rtgi_atlas` is fed automatically.

CSG nodes (CSGBox, CSGCombiner, ... any root CSG shape) are traced and receive GI too; their generated mesh gets the GI shader per surface.

Light/geometry changes: see **Instant lighting response** below.

Group `rtgi_ignore` excludes a node (and its children) from tracing/conversion.
Supported lights: DirectionalLight, OmniLight, SpotLight (with shadows from traced geometry).

## Build (prebuilt Linux x64 .so and Windows x64 .dll are included in bin/)
    git clone -b 3.5 --recursive https://github.com/godotengine/godot-cpp
    cd godot-cpp && scons platform=linux generate_bindings=yes target=release -j8 && cd ..
    cd rtgi && scons platform=linux target=release -j8       # osx likewise

    # Windows cross-compile with MinGW-w64 (posix threads); fully static, no extra DLLs needed:
    cd godot-cpp && scons platform=windows use_mingw=yes generate_bindings=yes target=release -j8 && cd ..
    cd rtgi && scons platform=windows use_mingw=yes target=release

## Godot 4 style SSAO (`rtgi_ssao.gd`, `shaders/rtgi_ssao.shader`)
Godot 3.5's built-in SSAO only darkens ambient light and looks coarse. This is a replacement modelled on Godot 4's SSAO:
an XeGTAO-style horizon search (slices x steps per pixel, normals rebuilt from depth) drawn as a full-screen quad that
multiplies onto the lit frame, so it also darkens RTGI light (which Godot's SSAO never touched). Pure GDScript + shader, no rebuild needed.

In the Environment inspector, tick **Godot 4 SSAO -> Enabled**: an `RTGI_SSAO` node is created next to the WorldEnvironment and the
Environment's built-in `ssao_enabled` is switched off (undoable). Manual alternative: add a Spatial with `res://addons/rtgi/rtgi_ssao.gd`.

| property | meaning |
|---|---|
| quality | Low / Medium / High / Ultra = 2x4 / 2x6 / 3x8 / 4x10 slices x steps. Lower = more grain |
| radius, intensity, power | same meaning and defaults as Godot 4 (1.0 / 2.5 / 1.5; intensity default raised from Godot 4's 2.0) |
| detail | 0..1, shifts samples towards the pixel for fine crease detail |
| horizon | occlusion below this amount is ignored (reduces self-occlusion on slopes) |
| strength | overall blend, 0 = off |
| fade_begin / fade_end | distance range over which the AO fades out |

Notes: it multiplies the whole lit frame (no separate ambient-only buffer in Godot 3), so Godot 4's `light_affect` / `ao_channel_affect`
don't exist; `strength` is the equivalent global knob. There is no blur pass, so low quality shows fine noise. Sky and transparent
surfaces are skipped (transparents draw after the AO). Needs a Camera in the viewport; works with perspective and orthogonal cameras.

## Per-pixel motion blur (`rtgi_motion_blur.gd`, `shaders/rtgi_motion_blur.shader`)
Port of the Godot 4 **JFA driven motion blur** CompositorEffect addon (Sphynx Motion Blur Toolkit: `PreBlurProcessor` + `SphynxSimpleJumpFloodMotionBlur`).
In the Environment inspector tick **Per-pixel Motion Blur -> Enabled**: an `RTGI_MotionBlur` node is created next to the WorldEnvironment (undoable). Manual alternative: add a Spatial with `res://addons/rtgi/rtgi_motion_blur.gd`. Pure GDScript + shader, no rebuild needed. Needs a Camera in the viewport (GLES3); it is hidden in the editor and only runs in the game.

Godot 3 has no compute shaders, velocity buffer or CompositorEffect, so the pass chain of the Godot 4 addon is folded into one full-screen quad (drawn right after the SSAO quad, before transparent objects):
1. **Velocity** per pixel from the depth buffer and the previous frame's camera, split into camera rotation / camera movement components with multiplier + lower/upper thresholds, exactly like `PreBlurProcessor` (sky = rotation only, never larger than the true camera velocity, clamped to one screen).
2. **Dilation**: the jump flood fitness search (nearest neighbour whose blur covers the pixel, perpendicular error limit) evaluated as a gather: `jfa_pass_count` levels of 8 taps at `sample_step_multiplier * (2 + step_exponent_modifier)^level` px, tile-jittered, instead of ping-pong passes.
3. **Blur**: the `jump_flood_simple_blur` gather: trail samples whose own blur reaches the pixel, depth aware foreground/background weighting and background reconstruction, noise-jittered samples.

| property | meaning |
|---|---|
| intensity | blur length multiplier (default 1.0) |
| quality | **Low / Medium / High / Custom** preset (default High = original look). Fills samples, jfa_pass_count, sample_step_multiplier, pixels_per_sample, fast_trail; editing any of them by hand switches to Custom. Also a drop-down in the Environment inspector under Per-pixel Motion Blur |
| samples | maximum blur samples per pixel (4..64, default 16) |
| pixels_per_sample | the sample count adapts to the blur length: one sample per this many px (default 1), capped by `samples` |
| fast_trail | cheap trail test, reads depth only instead of rebuilding the velocity of every sample |
| framerate_independent, target_constant_framerate, uncapped_independence | same as Godot 4: blur simulates a 1/30 s shutter (effective intensity = intensity * (1/target) / frame time, capped at one frame of motion unless uncapped) |
| perpen_error_threshold, sample_step_multiplier, step_exponent_modifier, jfa_pass_count | jump flood dilation settings. Max dilation radius (px) = (2 + step_exponent_modifier)^(jfa_pass_count - 1) * sample_step_multiplier (default 3^2 * 16 = 144 px) |
| depth_softness | relative depth range over which foreground / background weights fade (new; Godot 4 used a fixed raw-depth constant) |
| camera_rotation_* / camera_movement_* | multiplier, lower and upper threshold of each velocity component |
| debug_view | Off / own velocity / dilated velocity / object velocity (shows which moving meshes were picked up) |

Differences from the Godot 4 addon: per-object velocity is emulated (see **Moving object blur** below) since Godot 3 renders no velocity buffer; the blur is one pass instead of compute stages (tile max / neighbour max are replaced by the jittered gather); both velocities are scaled by `intensity` in the blur (Godot 4 applied it partly twice). Transparent surfaces draw after the blur and are not blurred. Call `reset()` after teleporting or cutting the camera to avoid one smeared frame.

## Moving object blur (`object_motion`, `object_multiplier`)
Meshes that move on their own are blurred too, not only camera motion. Every `MeshInstance` whose `global_transform` changed since the last frame
is drawn into a hidden helper viewport (own world, `ObjectVelocityViewport`) with `shaders/rtgi_velocity.shader`, which writes the pixel's full
screen-space velocity (previous model matrix + previous camera -> current) and its linear depth into a half-float texture. The blur shader reads
that texture: where the stored depth matches the scene depth (so occluded parts of an object are ignored) it uses the object velocity instead of the
camera-derived one, and the existing dilation / blur passes then smear the object's trail past its silhouette. Nothing to set up: moving meshes are found
automatically (new meshes are picked up as they enter the tree, plus a safety rescan every 300 frames); add a node to group `motion_blur_ignore` to exclude it. `object_multiplier` scales the object
velocity, `object_motion` switches the feature off. Not supported: skinned/bone animation, vertex-shader animation, transparent objects, and objects
that rotate/scale are only as accurate as one transform per frame. For offline rendering set `framerate_independent = false`.

The blur quad is drawn at priority -127 and the SSAO quad at -126 (the screen copy a screen-reading shader gets is taken before the transparent pass, so the order matters: AO is multiplied onto the already blurred frame).

### Motion blur performance
Presets (samples / jump levels / step px / px per sample / fast trail / cross dilation): **Low** 6 / 2 / 24 / 4 / on / on (max blur 72 px), **Medium** (default) 10 / 3 / 14 / 3 / on / off (126 px), **High** 16 / 3 / 16 / 1 / off / off (144 px).
The jump flood search is skipped while the camera only rotates and nothing moves (velocity is then independent of depth). The object velocity viewport only renders on frames where a mesh moved. Meshes idle for 30 frames are polled every 8 frames (a mesh that starts moving shows no blur for its first frame).
The full-screen pass is skipped while the camera is still and no object moves; the shader only reads the object-velocity texture on frames where a mesh actually moved.

## GI quality presets (`quality_preset`)
On the RTGI node (and in the Environment inspector's **RTGI -> GI Quality** drop-down): **Low Quality**, **High Quality** or **Custom**.
New nodes created by the plugin start on High Quality. A node without the property (old scenes) loads as Custom, i.e. exactly its saved settings.

| | Low Quality | High Quality |
|---|---|---|
| probe density (follows `bounds_size`) | 0.7 / m, max 1200 probes | 1.6 / m, max 6000 probes |
| rays per probe: instant / refinement | 8 / 32 | 10 / 192 |
| explicit diffuse bounces per path | 2 | 3 |
| probe feedback (infinite-bounce tail, refinement) | 0.7 | 0.97 |
| denoiser | 3 passes, strong | 3 passes, edge-preserving |
| refinement budget per frame | 4 ms | 10 ms |
| display smoothing (refinement only; changes show instantly) | 0.3 | 0.35 |
| memory / CPU | low | higher |

Low/High ignore the individual quality properties (`probes_x/y/z`, `rays_per_probe`, `probes_per_frame`, `trace_budget_ms`, `settle_sweeps`, `bounce_strength`, `display_smoothing`, `denoise*`, `blend`); they are used only by **Custom**, together with `instant_rays` and `instant_bounces`. Switching presets never overwrites your Custom values. `get_quality_info()` returns a one-line summary of what the active preset resolves to.

## Instant lighting response (all presets)
Every preset uses the same pipeline, so lights react immediately; only quality and cost differ.
1. **Detection**: each frame the node hashes geometry/materials and, separately, lights + sky. Moving, hiding/showing, recolouring or changing the energy of a light only changes the light hash, so the BVH is *not* rebuilt.
2. **Instant pass (same frame)**: on any change every probe is overwritten (blend = 1) with a fresh estimate from `instant_rays` rays, each following `bounces` explicit diffuse bounces with direct light + shadows at every hit. It uses no data from earlier probes, so there is no stale light to drain (no trails) and nothing waits for the grid to converge. A fixed seed keeps the noise identical frame to frame, so moving lights slide smoothly instead of flickering. The result is uploaded and shown in that same frame (no display smoothing).
3. **Refinement (after the initial result)**: following frames trace `rays_per_probe`-quality samples, adding the probe feedback tail and averaging noise away, within the per-frame budget. A new change interrupts refinement and runs the instant pass again.
4. **Responsiveness guard**: the instant pass always covers every probe, but if it is measured to take longer than ~10 ms (Low) / ~24 ms (High, Custom) per frame, it uses fewer rays per probe (min 2) until the light stops moving; refinement then restores the quality. Raising `thread_count` or lowering the probe count is the way to keep full instant quality on slow CPUs.
The node processes with a late priority, so light moves done in other scripts' `_process` the same frame are picked up that frame. `fast_sweeps` / `fast_blend` are kept for compatibility but no longer used (the instant pass replaces them). `sample_gi(position, normal)` reads the displayed probe grid on the CPU.

## Properties
| property | meaning |
|---|---|
| bounds_size, probes_x/y/z | world-space size and resolution of the probe grid (axis aligned, centered on node) |
| rays_per_probe, probes_per_frame, thread_count | quality vs. cost (thread_count 0 = all cores) |
| fast_sweeps, fast_blend | legacy, unused (superseded by the instant pass) |
| env_ambient_strength | share of the Environment's ambient light kept on converted materials (0 = RTGI only). Godot's SSAO only darkens ambient light, so it only affects this share; RTGI light is added as emission and is not touched by SSAO |
| trace_budget_ms | real-time mode: while updating, trace as many probes per frame as fit in this many ms (measured; `probes_per_frame` is the minimum). 0 = fixed `probes_per_frame` |
| display_smoothing | how fast the shown lighting follows the traced probes (1 = instant but noisier) |
| denoise | edge-aware spatial denoiser over the probe grid (on by default); removes the blotchy noise while lights/objects move |
| denoise_strength | 0..1, how much of the filtered result is used once probes have converged (freshly re-traced, noisy probes are always filtered harder, so this mainly affects the settled look) |
| denoise_edge | luminance edge-stop: lower keeps more contrast between neighbouring probes (sharper light/shadow boundaries), higher blurs more |
| denoise_passes | number of 3x3x3 filter passes (2 is about a 5x5x5 kernel; 3-4 for very noisy, low ray counts) |
| blend | minimum temporal blend factor (lower = smoother, slower to react) |
| bounce_strength | feedback of the previous probe grid at hit points (0 = single bounce, ~0.9 = many bounces) |
| intensity, normal_bias | shader-side GI strength and sampling offset along normal (reduces leaks) |
| radiance_clamp | firefly clamp |
| sky_energy | multiplier for the sky light taken from the Environment (its Sky: ProceduralSky, or PanoramaSky averaged into top/horizon/ground; else its background / ambient colour). Rays that escape see this sky; there are no separate sky colours any more |
| update_only_on_change, settle_sweeps | stop tracing when nothing moved, after N full probe sweeps |
| backface_black | rays hitting back faces return black (stops light leaking through single-sided walls) |

Methods: `rebuild()` (drop mesh cache), `reset()` (clear probes), `get_trace_ms()`, `get_ray_count()`, `is_settled()`.

## Limits
- Probe GI is low frequency (diffuse only), no specular/reflections; probes have no visibility term, so thin walls can leak (raise probe density, use `normal_bias`).
- Tracer uses flat albedo color per surface (textures are not sampled), and no transparency.
- Any moving mesh/light triggers a BVH rebuild (cheap for small scenes; keep dynamic scenes modest).
- Probes that end up inside solid geometry are detected (backface hits) and excluded from interpolation, but very thin or open meshes can still leak light.


## Texture-aware bounce light (`texture_albedo`, default on)
Bounce light is traced with each surface's real colour: linear(material colour) x average linear colour of its albedo texture
(cached per texture). Before, only the flat material colour was used, so a sandstone wall bounced neutral light. This is what makes
shadowed areas pick up warm/coloured light from sunlit surfaces. Because a flat white albedo no longer over-bounces, scenes tuned for
the old behaviour will look darker: raise `intensity` (and `sky_energy`) to compensate. Requires rebuilding the native library
(`src/rtgi.cpp`, `src/rtgi.h` changed); the shipped Windows DLL is the old build until you rebuild it.

## Default look
New RTGI nodes created by the plugin (and the C++ defaults after a rebuild) use a warm, tuned look: `sky_energy` 1.1, `intensity` 5.0, `radiance_clamp` 6, `bounce_strength` 0.97, `normal_bias` 1.8, 96 rays/probe.
The plugin applies these via `Util.apply_look()` in `rtgi_util.gd`, so the shipped binaries need no rebuild.

SSAO defaults are tuned for interiors: quality High (3x8), radius 3.0, intensity 3.5, power 1.6, detail 0.3, horizon 0.03 (wide enough to darken deep recesses such as window niches).

Anti-aliasing: enabling the plugin turns on MSAA 4x and FXAA in Project Settings (Rendering > Quality > Filters) if both are off.

## Sky and spot lights (flashlights)
- The sky is no longer configured on the RTGI node: `sky_top`, `sky_horizon`, `sky_ground` and `sky_from_environment` were removed. Escaping rays always use the WorldEnvironment's sky (changing the sky updates the GI instantly). Old scenes simply drop the removed values.
- Spot lights are injected as virtual point lights: a fixed pattern of 64 rays inside the cone marks the lit patches, and every probe gathers those patches directly (with shadow rays). A narrow beam used to be hit by almost none of a probe's random rays, so a flashlight in a dark scene lit nothing; now the lit spot bounces light onto the surrounding walls/floor even at Low quality. Up to 4 spot lights are handled this way. Requires rebuilding the native library.
