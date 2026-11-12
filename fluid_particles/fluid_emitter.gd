tool
extends Spatial
# FluidEmitter: runs a small particle-based fluid simulation (Clavet et al. 2005
# "Particle-based Viscoelastic Fluid Simulation": double-density relaxation,
# viscosity impulses and a cohesion/stickiness term) for all FluidStream children.
#
# Particles are simulated in WORLD space, so moving the emitter doesn't drag the
# fluid along with it.
#
# Rendering has two modes:
#  * Blended surface (default, GLES3): screen-space fluid rendering. The particles are
#    drawn as depth-writing sphere impostors in a hidden viewport, that depth is blurred
#    (bilateral filter) so neighbouring particles merge into one body, normals are
#    rebuilt from the blurred depth, and a full-screen quad shades the result with the
#    scene's own lights and reflections.
#  * Spheres: a MultiMesh of plain spheres (fallback for GLES2 / no camera found).
#
# Tip: keep total particle counts in the few-hundreds range. This is pure GDScript.

signal finished

const PRESET_NAMES = "Choose...,Water,Thick,Sticky,Spray,Clear Water,Milky,Milky Rope,Syrup,Slime,Sticky Goo,Slime Rope,Honey Glue,Clear Glue"

# Applied before every preset so switching presets never leaves sticky-goo settings behind.
const PRESET_RESET = {"stick_to_surfaces": false, "stick_hold": 0.85, "stick_slide": 0.0, "stick_chain": 0.0, "velocity_smoothing": 0.0}
const PRESETS = {
	# 1-4: solver behaviour only (they leave your colour / size alone)
	1: {"rest_density": 3.0, "stiffness": 10.0, "repulsion": 25.0, "viscosity": 25.0, "stickiness": 10.0},
	2: {"rest_density": 3.0, "stiffness": 8.0, "repulsion": 20.0, "viscosity": 80.0, "stickiness": 25.0},
	3: {"rest_density": 3.0, "stiffness": 8.0, "repulsion": 20.0, "viscosity": 40.0, "stickiness": 60.0},
	4: {"rest_density": 2.0, "stiffness": 6.0, "repulsion": 15.0, "viscosity": 5.0, "stickiness": 0.0},
	# 5-9: behaviour + look (colour, size, shininess, surface smoothing)
	5: {"rest_density": 3.0, "stiffness": 10.0, "repulsion": 25.0, "viscosity": 10.0, "viscosity_quad": 0.0, "stickiness": 8.0,
		"particle_size": 0.03, "visual_scale": 1.5, "interaction_radius": 2.0, "surface_smoothing": 1.2,
		"color": Color(0.6, 0.82, 1.0), "opacity": 0.5, "roughness": 0.02, "specular": 0.9, "rim_opacity": 0.6},
	6: {"rest_density": 3.0, "stiffness": 8.0, "repulsion": 20.0, "viscosity": 50.0, "viscosity_quad": 2.0, "stickiness": 35.0,
		"particle_size": 0.03, "visual_scale": 1.5, "interaction_radius": 2.0, "surface_smoothing": 1.3,
		"color": Color(0.97, 0.96, 0.93), "opacity": 0.97, "roughness": 0.12, "specular": 0.7, "rim_opacity": 0.2},
	7: {"rest_density": 3.0, "stiffness": 9.0, "repulsion": 18.0, "viscosity": 55.0, "viscosity_quad": 3.0, "stickiness": 55.0,
		"particle_size": 0.02, "visual_scale": 1.5, "interaction_radius": 2.2, "surface_smoothing": 1.4, "lifetime": 5.0,
		"color": Color(0.97, 0.96, 0.93), "opacity": 0.97, "roughness": 0.12, "specular": 0.7, "rim_opacity": 0.2},
	8: {"rest_density": 3.0, "stiffness": 8.0, "repulsion": 20.0, "viscosity": 90.0, "viscosity_quad": 4.0, "stickiness": 70.0,
		"particle_size": 0.03, "visual_scale": 1.5, "interaction_radius": 2.0, "surface_smoothing": 1.3,
		"color": Color(0.85, 0.5, 0.12), "opacity": 0.8, "roughness": 0.05, "specular": 0.9, "rim_opacity": 0.5},
	9: {"rest_density": 3.0, "stiffness": 8.0, "repulsion": 20.0, "viscosity": 70.0, "viscosity_quad": 3.0, "stickiness": 80.0,
		"particle_size": 0.03, "visual_scale": 1.5, "interaction_radius": 2.0, "surface_smoothing": 1.3,
		"color": Color(0.45, 0.9, 0.3), "opacity": 0.85, "roughness": 0.08, "specular": 0.8, "rim_opacity": 0.4},
	# 10-13: sticky goo. Thin, dense, calm lines that stick to the floor and to physics bodies.
	# Use them with the "Goo Line" / "Thick Goo Rope" / "Goo Splat" / "Long Goo Line" stream presets.
	# Sticks to everything it touches, then the rest of the line piles onto it. Barely sags.
	10: {"rest_density": 2.5, "stiffness": 6.0, "repulsion": 14.0, "viscosity": 80.0, "viscosity_quad": 4.0, "stickiness": 90.0,
		"particle_size": 0.022, "visual_scale": 1.7, "interaction_radius": 2.4, "surface_smoothing": 1.6, "lifetime": 25.0, "substeps": 3,
		"color": Color(0.96, 0.95, 0.9), "opacity": 0.98, "roughness": 0.15, "specular": 0.7, "rim_opacity": 0.2,
		"stick_to_surfaces": true, "stick_hold": 0.9, "stick_slide": 0.004, "stick_chain": 3.0, "velocity_smoothing": 0.5},
	# Green slime: the front sticks, the rest stays one continuous stretching rope (no chain sticking).
	11: {"rest_density": 2.5, "stiffness": 6.0, "repulsion": 14.0, "viscosity": 90.0, "viscosity_quad": 4.0, "stickiness": 100.0,
		"particle_size": 0.02, "visual_scale": 1.8, "interaction_radius": 2.6, "surface_smoothing": 1.8, "lifetime": 25.0, "substeps": 3,
		"color": Color(0.45, 0.9, 0.3), "opacity": 0.88, "roughness": 0.06, "specular": 0.85, "rim_opacity": 0.4,
		"stick_to_surfaces": true, "stick_hold": 0.85, "stick_slide": 0.01, "stick_chain": 0.0, "velocity_smoothing": 0.6},
	# Amber, very thick, creeps down walls extremely slowly.
	12: {"rest_density": 2.5, "stiffness": 6.0, "repulsion": 14.0, "viscosity": 100.0, "viscosity_quad": 5.0, "stickiness": 75.0,
		"particle_size": 0.022, "visual_scale": 1.7, "interaction_radius": 2.4, "surface_smoothing": 1.6, "lifetime": 30.0, "substeps": 3,
		"color": Color(0.9, 0.6, 0.1), "opacity": 0.85, "roughness": 0.04, "specular": 0.9, "rim_opacity": 0.5,
		"stick_to_surfaces": true, "stick_hold": 0.92, "stick_slide": 0.002, "stick_chain": 2.0, "velocity_smoothing": 0.5},
	# See-through glue that runs a bit more freely down walls.
	13: {"rest_density": 2.5, "stiffness": 6.0, "repulsion": 14.0, "viscosity": 70.0, "viscosity_quad": 3.0, "stickiness": 80.0,
		"particle_size": 0.022, "visual_scale": 1.7, "interaction_radius": 2.4, "surface_smoothing": 1.6, "lifetime": 25.0, "substeps": 3,
		"color": Color(0.8, 0.9, 1.0), "opacity": 0.45, "roughness": 0.03, "specular": 0.95, "rim_opacity": 0.6,
		"stick_to_surfaces": true, "stick_hold": 0.88, "stick_slide": 0.02, "stick_chain": 1.5, "velocity_smoothing": 0.5},
}

const SHADER_DEPTH = """
shader_type spatial;
// ALPHA is written below, which puts this in the transparent pass. depth_draw_always makes
// overlapping impostors depth-test against each other (nearest wins) instead of by draw order.
render_mode unshaded, cull_disabled, depth_draw_always;

uniform float depth_range = 100.0;

varying vec2 v_quad;
varying vec3 v_center;
varying float v_radius;

vec3 pack_depth(float v) {
	vec3 enc = fract(v * vec3(1.0, 255.0, 65025.0));
	enc -= enc.yzz * vec3(1.0 / 255.0, 1.0 / 255.0, 0.0);
	return enc;
}

void vertex() {
	float rad = length(WORLD_MATRIX[0].xyz);
	v_quad = VERTEX.xy;
	v_radius = rad;
	v_center = (INV_CAMERA_MATRIX * vec4(WORLD_MATRIX[3].xyz, 1.0)).xyz;
	mat4 bb = INV_CAMERA_MATRIX * mat4(CAMERA_MATRIX[0], CAMERA_MATRIX[1], CAMERA_MATRIX[2], WORLD_MATRIX[3]);
	bb[0] *= rad;
	bb[1] *= rad;
	bb[2] *= rad;
	MODELVIEW_MATRIX = bb;
}

void fragment() {
	float r2 = dot(v_quad, v_quad);
	if (r2 > 1.0) {
		discard;
	}
	float zz = sqrt(1.0 - r2);
	float zv = v_center.z + zz * v_radius;
	vec4 clip = PROJECTION_MATRIX * vec4(v_center.x + v_quad.x * v_radius, v_center.y + v_quad.y * v_radius, zv, 1.0);
	DEPTH = clip.z / clip.w * 0.5 + 0.5;
	float nd = clamp(-zv / depth_range, 0.0, 0.99999);
	ALBEDO = pack_depth(nd);
	// Particle pixels are valid depth samples; the transparent viewport clear
	// supplies alpha zero everywhere outside the impostors.
	ALPHA = 1.0;
}
"""

const SHADER_BLUR = """
shader_type canvas_item;
render_mode blend_premul_alpha;

// Reads the previous stage with the rect's own UV (0,0 = top-left of the image, which is how
// an upright ViewportTexture is addressed), so it does not depend on SCREEN_UV conventions.
uniform sampler2D src;
uniform vec2 tex_size = vec2(1280.0, 720.0);
uniform vec2 dir = vec2(1.0, 0.0);
uniform float depth_range = 100.0;
uniform float guess_depth = 3.0;
uniform float blur_world = 0.05;
uniform float p11 = 1.7;
uniform bool ortho = false;
uniform float depth_sigma = 0.03;
uniform float max_radius_px = 40.0;

const int N = 6;

float unpack_depth(vec3 c) {
	return dot(c, vec3(1.0, 1.0 / 255.0, 1.0 / 65025.0));
}

vec3 pack_depth(float v) {
	vec3 enc = fract(v * vec3(1.0, 255.0, 65025.0));
	enc -= enc.yzz * vec3(1.0 / 255.0, 1.0 / 255.0, 0.0);
	return enc;
}

float radius_px(float d, float pxy) {
	float r = blur_world * p11 * 0.5 / pxy;
	if (!ortho) {
		r = r / max(d, 0.01);
	}
	return clamp(r, 1.0, max_radius_px);
}

vec4 fetch(vec2 uv, vec2 px) {
	return textureLod(src, clamp(uv, px * 0.5, vec2(1.0) - px * 0.5), 0.0);
}

void fragment() {
	// NOTE: no 'return' anywhere in here. Godot 3.5 rejects it in fragment(), which
	// invalidates the whole shader (the blur stage then draws plain white = "fluid everywhere").
	vec2 px = 1.0 / tex_size;
	vec2 uv = (floor(UV * tex_size) + 0.5) * px;
	vec4 c0 = fetch(uv, px);
	float d_ref = 1.0e9;
	if (c0.a > 0.02) {
		d_ref = unpack_depth(c0.rgb) * depth_range;
	} else {
		float stepg = radius_px(guess_depth, px.y) / float(N);
		for (int i = -N; i <= N; i++) {
			vec4 s = fetch(uv + dir * round(float(i) * stepg) * px, px);
			if (s.a > 0.02) {
				d_ref = min(d_ref, unpack_depth(s.rgb) * depth_range);
			}
		}
	}

	vec4 result = vec4(0.0);
	if (d_ref < 1.0e8) {
		float step_px = radius_px(d_ref, px.y) / float(N);
		float a_acc = 0.0;
		float a_w = 0.0;
		float d_acc = 0.0;
		float d_w = 0.0;
		for (int i = -N; i <= N; i++) {
			float fi = float(i);
			float ws = exp(-0.5 * fi * fi / 9.0);
			vec4 s = fetch(uv + dir * round(fi * step_px) * px, px);
			a_acc += s.a * ws;
			a_w += ws;
			if (s.a > 0.02) {
				float ds = unpack_depth(s.rgb) * depth_range;
				float e = (ds - d_ref) / depth_sigma;
				float w = ws * exp(-0.5 * e * e) * s.a;
				d_acc += ds * w;
				d_w += w;
			}
		}
		float depth = d_ref;
		if (d_w > 0.0) {
			depth = d_acc / d_w;
		}
		result = vec4(pack_depth(clamp(depth / depth_range, 0.0, 0.99999)), a_acc / a_w);
	}
	COLOR = result;
}
"""

const SHADER_SURFACE = """
shader_type spatial;
render_mode cull_disabled, shadows_disabled;

uniform sampler2D fluid_tex;
uniform vec2 tex_size = vec2(1280.0, 720.0);
uniform float depth_range = 100.0;
uniform float threshold = 0.4;
uniform bool flip_y = false;
uniform int debug_mode = 0;
uniform vec4 fluid_color : hint_color = vec4(0.95, 0.95, 1.0, 1.0);
uniform float opacity = 1.0;
uniform float rough = 0.1;
uniform float spec = 0.6;
uniform float rim_alpha = 0.35;
uniform vec4 emit_color : hint_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emit_energy = 1.0;

float unpack_depth(vec3 c) {
	return dot(c, vec3(1.0, 1.0 / 255.0, 1.0 / 65025.0));
}

// The fluid texture is upright (v = 0 at the top of the image). We address it from the
// fragment's projected position (NDC, y up) so no SCREEN_UV convention is involved.
vec2 ndc_to_tex(vec2 ndc) {
	vec2 u = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
	if (flip_y) {
		u.y = 1.0 - u.y;
	}
	return (floor(u * tex_size) + 0.5) / tex_size;
}

vec2 tex_to_ndc(vec2 t) {
	if (flip_y) {
		t.y = 1.0 - t.y;
	}
	return vec2(t.x * 2.0 - 1.0, 1.0 - t.y * 2.0);
}

vec4 fetch(vec2 ndc) {
	return textureLod(fluid_tex, ndc_to_tex(ndc), 0.0);
}

float depth_of(vec4 c, float fallback) {
	if (c.a > 0.02) {
		return unpack_depth(c.rgb) * depth_range;
	}
	return fallback;
}

vec3 view_pos(mat4 P, vec2 ndc, float d) {
	if (P[3][3] > 0.5) {
		return vec3(ndc.x / P[0][0], ndc.y / P[1][1], -d);
	}
	return vec3(ndc.x * d / P[0][0], ndc.y * d / P[1][1], -d);
}

void fragment() {
	mat4 P = PROJECTION_MATRIX;
	vec4 pclip = P * vec4(VERTEX, 1.0);
	vec2 sc = tex_to_ndc(ndc_to_tex(pclip.xy / pclip.w));   // snapped to the texel centre
	vec4 c = fetch(sc);
	if (c.a < 0.02) {
		discard;
	}
	float cov = smoothstep(max(threshold - 0.12, 0.0), threshold + 0.12, c.a);
	if (cov < 0.004) {
		discard;
	}
	vec2 px = 2.0 / tex_size;   // one texel in NDC units
	float dC = unpack_depth(c.rgb) * depth_range;
	float dL = depth_of(fetch(sc - vec2(px.x, 0.0)), dC);
	float dR = depth_of(fetch(sc + vec2(px.x, 0.0)), dC);
	float dD = depth_of(fetch(sc - vec2(0.0, px.y)), dC);
	float dU = depth_of(fetch(sc + vec2(0.0, px.y)), dC);

	vec3 pC = view_pos(P, sc, dC);
	vec3 pL = view_pos(P, sc - vec2(px.x, 0.0), dL);
	vec3 pR = view_pos(P, sc + vec2(px.x, 0.0), dR);
	vec3 pD = view_pos(P, sc - vec2(0.0, px.y), dD);
	vec3 pU = view_pos(P, sc + vec2(0.0, px.y), dU);

	vec3 ddx = pR - pC;
	if (abs(dC - dL) < abs(dR - dC)) {
		ddx = pC - pL;
	}
	vec3 ddy = pU - pC;
	if (abs(dC - dD) < abs(dU - dC)) {
		ddy = pC - pD;
	}
	vec3 n = normalize(cross(ddx, ddy));

	vec4 clip = P * vec4(pC, 1.0);
	DEPTH = clip.z / clip.w * 0.5 + 0.5;

	vec3 v = normalize(-pC);
	float ndv = clamp(dot(n, v), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.0);

	ALBEDO = fluid_color.rgb;
	ROUGHNESS = rough;
	SPECULAR = spec;
	METALLIC = 0.0;
	NORMAL = n;
	EMISSION = emit_color.rgb * emit_energy;
	ALPHA = cov * clamp(opacity + fres * rim_alpha, 0.0, 1.0);

	if (debug_mode == 1) {
		ALBEDO = vec3(0.0);
		EMISSION = vec3(c.a);
		SPECULAR = 0.0;
		ALPHA = 1.0;
	} else if (debug_mode == 2) {
		ALBEDO = vec3(0.0);
		EMISSION = n * 0.5 + 0.5;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	}
}
"""

# --- Playback ---------------------------------------------------------------
export(bool) var autoplay = true
export(bool) var looping = false
# Seconds to wait between loops.
export(float, 0.0, 10.0, 0.05) var loop_delay = 0.5
# Preview (and loop) the effect inside the editor.
export(bool) var editor_preview = true
# Tick this in the editor to replay the preview.
export(bool) var replay = false setget _set_replay
export(float, 0.0, 4.0, 0.01) var time_scale = 1.0
# Simulation steps per physics frame. More = more stable, but slower.
export(int, 1, 6) var substeps = 2

# --- Particles --------------------------------------------------------------
# Diameter of each particle in meters.
export(float, 0.005, 0.5, 0.001) var particle_size = 0.04
# Interaction distance as a multiple of particle_size.
export(float, 1.0, 4.0, 0.05) var interaction_radius = 2.0
# Seconds a particle lives.
export(float, 0.1, 60.0, 0.1) var lifetime = 4.0
# Random shortening of lifetime (0..1).
export(float, 0.0, 1.0, 0.01) var lifetime_random = 0.0

# --- Fluid behaviour --------------------------------------------------------
# Off by default: tick this to enable the particle-to-particle fluid solver.
# When off, the effect is a much faster, purely ballistic spray (no particle interaction).
export(bool) var simulate_fluid = false
# How many particles want to overlap (higher = denser fluid).
export(float, 0.0, 10.0, 0.05) var rest_density = 3.0
# How incompressible the fluid is.
export(float, 0.0, 100.0, 0.1) var stiffness = 10.0
# Short-range repulsion that stops particles clumping onto one point.
export(float, 0.0, 200.0, 0.1) var repulsion = 25.0
# Resistance to shearing (thickness).
export(float, 0.0, 100.0, 0.1) var viscosity = 25.0
# Extra viscosity for fast-approaching particles (stability / splat).
export(float, 0.0, 100.0, 0.1) var viscosity_quad = 0.0
# How strongly particles stick together.
export(float, 0.0, 100.0, 0.1) var stickiness = 10.0
export(float, 0.0, 3.0, 0.01) var gravity_scale = 1.0
# Constant extra acceleration (wind, etc.) in m/s^2.
export(Vector3) var wind = Vector3.ZERO
# Air drag; 0 = none.
export(float, 0.0, 10.0, 0.01) var drag = 0.0
export(float, 1.0, 200.0, 1.0) var speed_limit = 30.0
# Averages each particle's velocity with its neighbours. Takes out jitter / shaking and makes the
# fluid move as one body. 0 = off.
export(float, 0.0, 1.0, 0.01) var velocity_smoothing = 0.0

# --- Sticking to surfaces ---------------------------------------------------
# Particles that touch the floor or a physics body (or, with stick_chain, other stuck particles)
# become anchored where they touched. Physics-body contact needs collide_with_world (game only).
export(bool) var stick_to_surfaces = false
# How firmly a stuck particle stays on its anchor (1 = rock solid, lower = squishier).
export(float, 0.0, 1.0, 0.01) var stick_hold = 0.85
# How fast stuck goo sags down a vertical wall, in m/s (0 = never slides).
export(float, 0.0, 0.5, 0.001) var stick_slide = 0.0
# How quickly particles touching stuck goo become stuck too (per second). 0 = only the surface
# contact sticks and the rest of the line stays a flowing, stretching rope.
export(float, 0.0, 30.0, 0.1) var stick_chain = 0.0

# --- World ------------------------------------------------------------------
# Simple infinite floor (global Y). Works in the editor preview too.
export(bool) var floor_enabled = false
export(float) var floor_height = 0.0
# Delete particles that fall below this global Y (like Blender's "particle catcher").
export(bool) var kill_height_enabled = false
export(float) var kill_height = -5.0
# Collide with physics bodies using a ray per particle (game only, not editor).
export(bool) var collide_with_world = true
export(int, LAYERS_3D_PHYSICS) var collision_mask = 1
export(float, 0.0, 1.0, 0.01) var collision_bounce = 0.0
export(float, 0.0, 1.0, 0.01) var collision_friction = 0.3

# --- Look -------------------------------------------------------------------
export(Color, RGB) var color = Color(0.95, 0.9, 1.0)
export(float, 0.0, 1.0, 0.01) var roughness = 0.1
# 1 = opaque, lower = see-through.
export(float, 0.0, 1.0, 0.01) var opacity = 1.0
export(Color, RGB) var emission_color = Color(0, 0, 0)
export(float, 0.0, 16.0, 0.1) var emission_energy = 1.0
# Rendered sphere size relative to particle_size. Bigger = fatter, more merged fluid.
export(float, 0.2, 4.0, 0.05) var visual_scale = 1.6
# Shrink particles during the last 0.25 s of their life.
export(bool) var fade_out_at_end = true
export(bool) var cast_shadows = false
# Use your own material instead of the generated one (this forces the plain sphere mode).
export(Material) var custom_material

# --- Blended surface --------------------------------------------------------
# Draw the particles as one blended fluid surface instead of separate balls.
export(bool) var fluid_surface = true
# How strongly neighbouring particles are smoothed together, in particle sizes.
# Low = lumpy / droplets, high = smooth blob.
export(float, 0.0, 6.0, 0.05) var surface_smoothing = 1.2
# Blur coverage level that counts as "fluid". Lower = fatter, gaps fill in; higher = thinner.
export(float, 0.1, 0.9, 0.01) var surface_threshold = 0.4
# Resolution of the hidden fluid buffers relative to the screen (lower = faster, softer).
export(float, 0.25, 1.0, 0.05) var surface_resolution = 1.0
# Highlight strength.
export(float, 0.0, 1.0, 0.01) var specular = 0.6
# Extra opacity at grazing angles (for see-through fluids).
export(float, 0.0, 1.0, 0.01) var rim_opacity = 0.35
# Troubleshooting: 1 = coverage mask, 2 = normals.
export(int, "Off", "Coverage", "Normals") var surface_debug = 0
# Troubleshooting: tick this if the fluid appears upside-down / mirrored.
export(bool) var surface_flip_y = false

const BIAS = 1048576            # 2^20, keeps cell coordinates positive
const STRIDE_Y = 2097152        # 2^21
const STRIDE_Z = 4398046511104  # 2^42
const FADE_TIME = 0.25

var _mmi = null
var _mm = null

var _active = false      # a run is in progress or waiting to loop
var _running = false     # simulating right now
var _time = 0.0
var _wait = 0.0
var _restart_queued = false

var _pos = []
var _vel = []
var _age = []
var _life = []
var _sid = []
var _fp = []             # position at the end of the previous physics frame (for collision rays)
var _stk = []            # stuck to a surface?
var _anc = []            # anchor position of a stuck particle
var _snr = []            # surface normal at the anchor
var _dv = []
var _dw = []
var _prev = []
var _n = 0

var _streams = []
var _links = []

var _grid = {}
var _half_offsets = []
var _pi = []
var _pj = []
var _gr = []
var _gn = []
var _rho = []
var _rhon = []

var _mat_sig = []
var _preset_shown = 0

var _sphere_mesh = null
var _quad_mesh = null
var _mm_count = 1

# Blended-surface renderer
var _surface_ok = null        # null = not checked yet
var _surface_on = false
var _surf_active = false
var _cam = null
var _cam_timer = 0.0
var _vp_a = null
var _vp_b = null
var _vp_c = null
var _fcam = null
var _rect_b = null
var _rect_c = null
var _quad = null
var _mat_a = null
var _mat_b = null
var _mat_c = null
var _mat_q = null
var _surf_size = Vector2.ZERO
var _quad_delay = 0
var _inactive_frames = 0
var _bounds_valid = false
var _bmin = Vector3.ZERO
var _bmax = Vector3.ZERO


func _is_fluid_emitter():
	return true


func _enter_tree():
	# Re-sync the hidden camera and the screen quad with the real camera right before drawing,
	# after every node (camera, animation, bone attachment...) has moved this frame.
	if not VisualServer.is_connected("frame_pre_draw", self, "_late_sync"):
		VisualServer.connect("frame_pre_draw", self, "_late_sync")


func _exit_tree():
	if VisualServer.is_connected("frame_pre_draw", self, "_late_sync"):
		VisualServer.disconnect("frame_pre_draw", self, "_late_sync")


func _ready():
	_build_half_offsets()
	_ensure_renderer()
	set_physics_process(true)
	set_process(true)
	if Engine.editor_hint:
		if editor_preview:
			restart()
	elif autoplay:
		restart()


# --- Public API -------------------------------------------------------------

# Start (or restart) the effect from the beginning.
func restart():
	_restart_queued = false
	_ensure_renderer()
	_collect_streams()
	_clear_particles()
	_time = 0.0
	_wait = 0.0
	var total = 0
	for s in _streams:
		total += s.count
	_mm_count = int(max(total, 1))
	_mm.instance_count = _mm_count
	_mm.visible_instance_count = 0
	_bounds_valid = false
	_running = total > 0
	_active = _running
	_update_material()


# Stop emitting and remove all particles.
func stop():
	_active = false
	_running = false
	_clear_particles()
	_bounds_valid = false
	if _mm != null:
		_mm.visible_instance_count = 0


func is_playing():
	return _running


# --- Setup ------------------------------------------------------------------

func _set_replay(v):
	if v and is_inside_tree():
		call_deferred("restart")
		call_deferred("property_list_changed_notify")


func _on_stream_changed():
	if Engine.editor_hint and editor_preview and is_inside_tree() and not _restart_queued:
		_restart_queued = true
		call_deferred("restart")


func _get_configuration_warning():
	for c in get_children():
		if c.has_method("_is_fluid_stream"):
			return ""
	return "Add at least one FluidStream child node to give this emitter something to shoot."


func _build_half_offsets():
	_half_offsets.clear()
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dz > 0 or (dz == 0 and dy > 0) or (dz == 0 and dy == 0 and dx > 0):
					_half_offsets.append(dx + dy * STRIDE_Y + dz * STRIDE_Z)


func _ensure_renderer():
	if _mmi != null and is_instance_valid(_mmi):
		return
	# Remove leftovers from an earlier run of this script (tool scripts get reloaded in the editor).
	for nm in ["_FluidSurfaceA", "_FluidSurfaceB", "_FluidSurfaceC", "_FluidQuad"]:
		if has_node(nm):
			var old = get_node(nm)
			remove_child(old)
			old.queue_free()
	_vp_a = null
	_vp_b = null
	_vp_c = null
	_quad = null
	_surface_on = false
	_surf_active = false
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 1.0
	_sphere_mesh.height = 2.0
	_sphere_mesh.radial_segments = 12
	_sphere_mesh.rings = 6
	if has_node("_FluidRenderer"):
		_mmi = get_node("_FluidRenderer")
		_mm = _mmi.multimesh
		_mm.mesh = _sphere_mesh
		return
	_mmi = MultiMeshInstance.new()
	_mmi.name = "_FluidRenderer"
	_mmi.set_as_toplevel(true)   # identity transform -> particle positions are world positions
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.color_format = MultiMesh.COLOR_NONE
	_mm.mesh = _sphere_mesh
	_mm.instance_count = 1
	_mm.visible_instance_count = 0
	_mmi.multimesh = _mm
	add_child(_mmi)   # no owner set, so it is never saved into the scene


func _update_material():
	if _mmi == null:
		return
	_mat_sig = _material_signature()
	_mmi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_ON if (cast_shadows and not _surface_on) else GeometryInstance.SHADOW_CASTING_SETTING_OFF
	if _surface_on:
		return   # the surface material is refreshed every frame
	if custom_material != null:
		_mmi.material_override = custom_material
		return
	var m = SpatialMaterial.new()
	m.albedo_color = Color(color.r, color.g, color.b, opacity)
	m.roughness = roughness
	m.metallic_specular = 0.8
	if opacity < 0.999:
		m.flags_transparent = true
	if emission_color != Color(0, 0, 0):
		m.emission_enabled = true
		m.emission = emission_color
		m.emission_energy = emission_energy
	_mmi.material_override = m


func _material_signature():
	return [color, roughness, opacity, emission_color, emission_energy, cast_shadows, custom_material, fluid_surface]


func _collect_streams():
	_streams.clear()
	_links.clear()
	for c in get_children():
		if c.has_method("_is_fluid_stream") and c.enabled:
			_streams.append({
				"node": c,
				"count": int(c.count),
				"start": float(c.start_delay),
				"dur": max(0.001, float(c.duration)),
				"emitted": 0,
			})
			_links.append(int(c.link))


func _clear_particles():
	_pos.clear()
	_vel.clear()
	_age.clear()
	_life.clear()
	_sid.clear()
	_fp.clear()
	_stk.clear()
	_anc.clear()
	_snr.clear()
	_n = 0


# --- Main loop --------------------------------------------------------------

func _physics_process(delta):
	if _mmi == null:
		return
	if _material_signature() != _mat_sig:
		_update_material()

	if not _running:
		# Waiting to loop?
		if _active and (looping or (Engine.editor_hint and editor_preview)):
			_wait += delta
			if _wait >= loop_delay:
				restart()
		return

	var dt = delta * time_scale
	if dt <= 0.0:
		return
	var sub = int(max(1, substeps))
	var sdt = dt / sub
	for _i in range(sub):
		_step(sdt)

	if collide_with_world and _n > 0:
		_world_collisions()
	for i in range(_n):
		_fp[i] = _pos[i]

	_update_render()

	if _n == 0 and _all_emitted():
		_running = false
		_wait = 0.0
		if not (looping or (Engine.editor_hint and editor_preview)):
			_active = false
		emit_signal("finished")


func _all_emitted():
	for s in _streams:
		if s.emitted < s.count:
			return false
	return true


func _step(dt):
	_time += dt
	_emit()
	_age_and_cull(dt)
	if _n == 0:
		return

	# Forces
	var accel = Vector3(0.0, -9.81 * gravity_scale, 0.0) + wind
	var damp = max(0.0, 1.0 - drag * dt)
	for i in range(_n):
		_vel[i] = (_vel[i] + accel * dt) * damp

	var h = particle_size * interaction_radius
	var fluid = simulate_fluid and _n > 1 and h > 0.0001
	if fluid:
		_build_pairs(h)
		_apply_viscosity(dt, h)
		if velocity_smoothing > 0.0:
			_smooth_velocities(h)

	# Predict positions
	_prev.resize(_n)
	for i in range(_n):
		_prev[i] = _pos[i]
		_pos[i] = _pos[i] + _vel[i] * dt

	if fluid:
		_relax(dt, h)

	# Floor, sticking and velocity update
	var rad = particle_size * 0.5
	var lim2 = speed_limit * speed_limit
	var inv_dt = 1.0 / dt
	var stick = stick_to_surfaces
	if fluid and stick and stick_chain > 0.0:
		_chain_stick(dt)
	for i in range(_n):
		var p = _pos[i]
		if floor_enabled and p.y < floor_height + rad:
			var pv = _prev[i]
			p.y = floor_height + rad
			p.x += (pv.x - p.x) * collision_friction
			p.z += (pv.z - p.z) * collision_friction
			_pos[i] = p
			if stick and not _stk[i]:
				_stk[i] = true
				_anc[i] = p
				_snr[i] = Vector3.UP
		if stick and _stk[i]:
			var a = _anc[i]
			if stick_slide > 0.0:
				# Creep along the surface in the direction gravity pulls along it.
				var sn = _snr[i]
				var tg = accel - sn * accel.dot(sn)
				var tl = tg.length()
				var al = accel.length()
				if tl > 0.0001 and al > 0.0001:
					a += tg * (stick_slide * dt / al)
				if floor_enabled and a.y < floor_height + rad:
					a.y = floor_height + rad
				_anc[i] = a
			p = a + (p - a) * (1.0 - stick_hold)
			_pos[i] = p
		var v = (p - _prev[i]) * inv_dt
		var sp2 = v.length_squared()
		if sp2 > lim2:
			v = v * (speed_limit / sqrt(sp2))
		_vel[i] = v


# --- Emission / lifetime ----------------------------------------------------

func _emit():
	for si in range(_streams.size()):
		var s = _streams[si]
		if s.emitted >= s.count:
			continue
		var node = s.node
		if not is_instance_valid(node) or not node.is_inside_tree():
			s.emitted = s.count
			continue
		var st = _time - s.start
		if st < 0.0:
			continue
		var tn = st / s.dur
		var target = s.count
		if tn < 1.0:
			target = int(s.count * node.emitted_fraction(tn))
		while s.emitted < target:
			var u = (s.emitted + 0.5) / s.count
			var smp = node.sample(u)
			var tk = s.start + s.dur * smp.x
			_spawn(si, s, clamp(_time - tk, 0.0, 0.1), smp.y)
			s.emitted += 1


func _spawn(si, s, sub, speed):
	var node = s.node
	var tr = node.global_transform
	var fwd = -tr.basis.z.normalized()
	var right = tr.basis.x.normalized()
	var up = tr.basis.y.normalized()

	var dir = fwd
	if node.spread_degrees > 0.0:
		var phi = randf() * TAU
		var theta = deg2rad(node.spread_degrees) * sqrt(randf())
		dir = (fwd * cos(theta) + (right * cos(phi) + up * sin(phi)) * sin(theta)).normalized()

	var origin = tr.origin
	if node.nozzle_radius > 0.0:
		var a = randf() * TAU
		var r = sqrt(randf()) * node.nozzle_radius
		origin += right * (cos(a) * r) + up * (sin(a) * r)

	if node.velocity_random > 0.0:
		speed *= 1.0 + (randf() * 2.0 - 1.0) * node.velocity_random

	var v = dir * speed
	var p = origin + v * sub
	_pos.append(p)
	_vel.append(v)
	_age.append(0.0)
	_life.append(lifetime * (1.0 - randf() * lifetime_random))
	_sid.append(si)
	_fp.append(p)
	_stk.append(false)
	_anc.append(p)
	_snr.append(Vector3.UP)
	_n += 1


func _age_and_cull(dt):
	var i = 0
	while i < _n:
		_age[i] += dt
		var dead = _age[i] >= _life[i]
		if not dead and kill_height_enabled and _pos[i].y < kill_height:
			dead = true
		if dead:
			_remove(i)
		else:
			i += 1


func _remove(i):
	var last = _n - 1
	if i != last:
		_pos[i] = _pos[last]
		_vel[i] = _vel[last]
		_age[i] = _age[last]
		_life[i] = _life[last]
		_sid[i] = _sid[last]
		_fp[i] = _fp[last]
		_stk[i] = _stk[last]
		_anc[i] = _anc[last]
		_snr[i] = _snr[last]
	_pos.pop_back()
	_vel.pop_back()
	_age.pop_back()
	_life.pop_back()
	_sid.pop_back()
	_fp.pop_back()
	_stk.pop_back()
	_anc.pop_back()
	_snr.pop_back()
	_n -= 1


# --- Fluid solver -----------------------------------------------------------

func _cell_key(cx, cy, cz):
	return (cx + BIAS) + (cy + BIAS) * STRIDE_Y + (cz + BIAS) * STRIDE_Z


func _build_pairs(h):
	var inv = 1.0 / h
	var reach2 = h * h * 1.5   # a little slack: positions move a bit before relaxation
	_grid.clear()
	for i in range(_n):
		var p = _pos[i]
		var key = _cell_key(int(floor(p.x * inv)), int(floor(p.y * inv)), int(floor(p.z * inv)))
		var cell = _grid.get(key)
		if cell == null:
			_grid[key] = [i]
		else:
			cell.append(i)

	_pi.clear()
	_pj.clear()
	for key in _grid:
		var cell = _grid[key]
		var cn = cell.size()
		for a in range(cn):
			var i = cell[a]
			var pi_pos = _pos[i]
			var si = _sid[i]
			for b in range(a + 1, cn):
				var j = cell[b]
				var sj = _sid[j]
				if si == sj or (_links[si] != 0 and _links[sj] != 0):
					if (_pos[j] - pi_pos).length_squared() < reach2:
						_pi.append(i)
						_pj.append(j)
		for off in _half_offsets:
			var other = _grid.get(key + off)
			if other == null:
				continue
			for i in cell:
				var pi_pos2 = _pos[i]
				var si2 = _sid[i]
				for j in other:
					var sj2 = _sid[j]
					if si2 == sj2 or (_links[si2] != 0 and _links[sj2] != 0):
						if (_pos[j] - pi_pos2).length_squared() < reach2:
							_pi.append(i)
							_pj.append(j)


func _apply_viscosity(dt, h):
	var sigma = viscosity * 0.1
	var beta = viscosity_quad * 0.1
	if sigma <= 0.0 and beta <= 0.0:
		return
	var inv_h = 1.0 / h
	var h2 = h * h
	for k in range(_pi.size()):
		var i = _pi[k]
		var j = _pj[k]
		var d = _pos[j] - _pos[i]
		var r2 = d.length_squared()
		if r2 >= h2 or r2 < 0.0000000001:
			continue
		var r = sqrt(r2)
		var n = d / r
		var u = (_vel[i] - _vel[j]).dot(n)
		if u > 0.0:
			var imp = dt * (1.0 - r * inv_h) * (sigma * u + beta * u * u)
			if imp > u:
				imp = u
			var iv = n * (imp * 0.5)
			_vel[i] -= iv
			_vel[j] += iv


func _relax(dt, h):
	var pc = _pi.size()
	if pc == 0:
		return
	var inv_h = 1.0 / h
	var h2 = h * h
	_rho.resize(_n)
	_rhon.resize(_n)
	for i in range(_n):
		_rho[i] = 0.0
		_rhon[i] = 0.0
	_gr.resize(pc)
	_gn.resize(pc)

	# Pass 1: densities
	for k in range(pc):
		var i = _pi[k]
		var j = _pj[k]
		var d = _pos[j] - _pos[i]
		var r2 = d.length_squared()
		if r2 >= h2:
			_gr[k] = -1.0
			continue
		var r
		var nrm
		if r2 < 0.0000000001:
			# Particles exactly on top of each other: push them apart in a random direction.
			nrm = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
			if nrm == Vector3.ZERO:
				nrm = Vector3.UP
			r = 0.0001
		else:
			r = sqrt(r2)
			nrm = d / r
		var om = 1.0 - r * inv_h
		var om2 = om * om
		var om3 = om2 * om
		_rho[i] += om2
		_rho[j] += om2
		_rhon[i] += om3
		_rhon[j] += om3
		_gr[k] = r
		_gn[k] = nrm

	# Pass 2: displacements
	var dt2 = dt * dt
	var L = particle_size
	var cohesion = stickiness > 0.0 and L < h
	var max_disp = h * 0.5
	for k in range(pc):
		var r = _gr[k]
		if r < 0.0:
			continue
		var i = _pi[k]
		var j = _pj[k]
		var om = 1.0 - r * inv_h
		var pressure = stiffness * (0.5 * (_rho[i] + _rho[j]) - rest_density)
		var near = repulsion * 0.5 * (_rhon[i] + _rhon[j])
		var D = dt2 * (pressure * om + near * om * om)
		if cohesion and r > L:
			D += dt2 * stickiness * (1.0 - L * inv_h) * (L - r)
		D = clamp(D, -max_disp, max_disp)
		var disp = _gn[k] * D
		_pos[i] -= disp
		_pos[j] += disp


# Pulls each particle's velocity towards the weighted average of its neighbours (XSPH-style).
func _smooth_velocities(h):
	var inv_h = 1.0 / h
	var h2 = h * h
	_dv.resize(_n)
	_dw.resize(_n)
	for i in range(_n):
		_dv[i] = Vector3.ZERO
		_dw[i] = 0.0
	for k in range(_pi.size()):
		var i = _pi[k]
		var j = _pj[k]
		var r2 = (_pos[j] - _pos[i]).length_squared()
		if r2 >= h2:
			continue
		var w = 1.0 - sqrt(r2) * inv_h
		_dv[i] += _vel[j] * w
		_dv[j] += _vel[i] * w
		_dw[i] += w
		_dw[j] += w
	var amt = velocity_smoothing * 0.5
	for i in range(_n):
		if _dw[i] > 0.0:
			_vel[i] = _vel[i].linear_interpolate(_dv[i] / _dw[i], amt)


# Free particles that touch stuck goo become stuck themselves (goo sticks to goo).
func _chain_stick(dt):
	var chance = 1.0 - exp(-stick_chain * dt)
	var touch2 = particle_size * particle_size * 1.44
	for k in range(_pi.size()):
		var i = _pi[k]
		var j = _pj[k]
		if _stk[i] == _stk[j]:
			continue
		if (_pos[j] - _pos[i]).length_squared() > touch2:
			continue
		if randf() < chance:
			var loose = i
			var fixed = j
			if _stk[i]:
				loose = j
				fixed = i
			_stk[loose] = true
			_anc[loose] = _pos[loose]
			_snr[loose] = _snr[fixed]


# --- Collision with physics bodies ------------------------------------------

func _world_collisions():
	var w = get_world()
	if w == null:
		return
	var space = w.direct_space_state
	if space == null:
		return
	var rad = particle_size * 0.5
	for i in range(_n):
		if stick_to_surfaces and _stk[i]:
			continue   # already stuck: it is held by its anchor
		var a = _fp[i]
		var b = _pos[i]
		var seg = b - a
		var len2 = seg.length_squared()
		if len2 < 0.000001:
			continue
		var dir = seg / sqrt(len2)
		var hit = space.intersect_ray(a, b + dir * rad, [], collision_mask)
		if hit.empty():
			continue
		var nrm = hit.normal
		_pos[i] = hit.position + nrm * (rad + 0.001)
		if stick_to_surfaces:
			_stk[i] = true
			_anc[i] = _pos[i]
			_snr[i] = nrm
			_vel[i] = Vector3.ZERO
			continue
		var v = _vel[i]
		var vn = v.dot(nrm)
		var vt = v - nrm * vn
		if vn < 0.0:
			vn = -vn * collision_bounce
		_vel[i] = vt * (1.0 - collision_friction) + nrm * vn


# --- Rendering --------------------------------------------------------------

func _update_render():
	var r = particle_size * 0.5 * visual_scale
	var track = _surface_on
	var mn = Vector3(1.0e20, 1.0e20, 1.0e20)
	var mx = Vector3(-1.0e20, -1.0e20, -1.0e20)
	for i in range(_n):
		var rr = r
		if fade_out_at_end:
			var remaining = _life[i] - _age[i]
			if remaining < FADE_TIME:
				rr = r * clamp(remaining / FADE_TIME, 0.0, 1.0)
		var b = Basis(Vector3(rr, 0, 0), Vector3(0, rr, 0), Vector3(0, 0, rr))
		var p = _pos[i]
		_mm.set_instance_transform(i, Transform(b, p))
		if track:
			if p.x < mn.x:
				mn.x = p.x
			if p.y < mn.y:
				mn.y = p.y
			if p.z < mn.z:
				mn.z = p.z
			if p.x > mx.x:
				mx.x = p.x
			if p.y > mx.y:
				mx.y = p.y
			if p.z > mx.z:
				mx.z = p.z
	_mm.visible_instance_count = _n
	_bounds_valid = track and _n > 0
	if _bounds_valid:
		var pad = Vector3(1, 1, 1) * (r + particle_size * surface_smoothing + 0.02)
		_bmin = mn - pad
		_bmax = mx + pad


# --- Blended surface (screen-space fluid) ---------------------------------

func _process(delta):
	if _mmi == null or not is_instance_valid(_mmi):
		return
	if Engine.editor_hint:
		_cam_timer -= delta
		if _cam == null or not is_instance_valid(_cam) or _cam_timer <= 0.0:
			_cam = _find_editor_camera()
			_cam_timer = 1.0
	else:
		var vp = get_viewport()
		_cam = vp.get_camera() if vp != null else null
	var want = _want_surface()
	if want != _surface_on:
		_set_surface(want)
	if _surface_on:
		_update_surface()


func _want_surface():
	if not fluid_surface or custom_material != null:
		return false
	if _surface_ok == null:
		_surface_ok = _check_surface_support()
	if not _surface_ok:
		return false
	return _cam != null and is_instance_valid(_cam) and _cam.is_inside_tree()


func _check_surface_support():
	if OS.get_current_video_driver() != OS.VIDEO_DRIVER_GLES3:
		print("[FluidEmitter] The blended surface needs the GLES3 renderer; drawing plain spheres instead.")
		return false
	var vp = Viewport.new()
	var ok = false
	for p in vp.get_property_list():
		if p.name == "keep_3d_linear":
			ok = true
	vp.free()
	if not ok:
		print("[FluidEmitter] The blended surface needs Godot 3.4 or newer; drawing plain spheres instead.")
	return ok


# The editor's 3D camera isn't reachable through the normal API, so look for it in the editor UI.
func _find_editor_camera():
	var best = null
	var best_area = -1.0
	var stack = [get_tree().root]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n.get_class() == "SpatialEditorViewport":
			if n.is_visible_in_tree():
				var cam = _first_camera(n)
				if cam != null:
					var area = n.rect_size.x * n.rect_size.y
					if area > best_area:
						best = cam
						best_area = area
			continue
		for c in n.get_children():
			stack.append(c)
	return best


func _first_camera(root):
	var stack = [root]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n is Camera:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _move_renderer(new_parent):
	var p = _mmi.get_parent()
	if p == new_parent:
		return
	if p != null:
		p.remove_child(_mmi)
	new_parent.add_child(_mmi)


func _set_surface(on):
	if on:
		_build_surface()
		_surface_on = true
		if _quad_mesh == null:
			_quad_mesh = QuadMesh.new()
			_quad_mesh.size = Vector2(2, 2)
		_mm.mesh = _quad_mesh
		_mmi.material_override = _mat_a
		_mmi.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
		_move_renderer(_vp_a)
	else:
		_surface_on = false
		if _vp_a != null and is_instance_valid(_vp_a):
			_set_surface_active(false)
		_mm.mesh = _sphere_mesh
		_move_renderer(self)
		_update_material()
		_bounds_valid = false


func _make_viewport(is_3d):
	var vp = Viewport.new()
	vp.size = Vector2(16, 16)
	vp.transparent_bg = true
	vp.gui_disable_input = true
	vp.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = Viewport.UPDATE_DISABLED
	# Godot 3 ViewportTextures are vertically inverted by default. With v_flip every stage
	# is an upright image (v = 0 at the top), which the blur passes address with their rect
	# UV and the final surface addresses from its projected screen position.
	vp.render_target_v_flip = true
	vp.msaa = Viewport.MSAA_DISABLED
	if is_3d:
		vp.own_world = true
		vp.set("keep_3d_linear", true)   # packed depth must not receive sRGB conversion
		vp.usage = Viewport.USAGE_3D
	else:
		vp.usage = Viewport.USAGE_2D
	return vp


func _make_rect(mat):
	var r = ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.material = mat
	return r


func _build_surface():
	if _vp_a != null and is_instance_valid(_vp_a):
		return
	_surf_size = Vector2.ZERO

	var sh_a = Shader.new()
	sh_a.code = SHADER_DEPTH
	_mat_a = ShaderMaterial.new()
	_mat_a.shader = sh_a
	var sh_b = Shader.new()
	sh_b.code = SHADER_BLUR
	_mat_b = ShaderMaterial.new()
	_mat_b.shader = sh_b
	_mat_c = ShaderMaterial.new()
	_mat_c.shader = sh_b
	var sh_q = Shader.new()
	sh_q.code = SHADER_SURFACE
	_mat_q = ShaderMaterial.new()
	_mat_q.shader = sh_q

	# The viewports are added in order A, B, C so they render in that order every frame.
	_vp_a = _make_viewport(true)
	_vp_a.name = "_FluidSurfaceA"
	_fcam = Camera.new()
	var fluid_env = Environment.new()
	# A transparent clear is essential: the surface quad uses the viewport alpha
	# as its coverage mask. An opaque clear would turn the camera-sized quad white.
	fluid_env.background_mode = Environment.BG_COLOR
	fluid_env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	_fcam.environment = fluid_env
	_vp_a.add_child(_fcam)
	_fcam.current = true
	add_child(_vp_a)

	_vp_b = _make_viewport(false)
	_vp_b.name = "_FluidSurfaceB"
	_rect_b = _make_rect(_mat_b)
	_vp_b.add_child(_rect_b)
	add_child(_vp_b)

	_vp_c = _make_viewport(false)
	_vp_c.name = "_FluidSurfaceC"
	_rect_c = _make_rect(_mat_c)
	_vp_c.add_child(_rect_c)
	add_child(_vp_c)

	_mat_b.set_shader_param("src", _vp_a.get_texture())
	_mat_b.set_shader_param("dir", Vector2(1, 0))
	_mat_c.set_shader_param("src", _vp_b.get_texture())
	_mat_c.set_shader_param("dir", Vector2(0, 1))
	_mat_q.set_shader_param("fluid_tex", _vp_c.get_texture())

	_quad = MeshInstance.new()
	_quad.name = "_FluidQuad"
	_quad.set_as_toplevel(true)
	var qm = QuadMesh.new()
	qm.size = Vector2(2, 2)
	_quad.mesh = qm
	_quad.material_override = _mat_q
	_quad.cast_shadow = GeometryInstance.SHADOW_CASTING_SETTING_OFF
	_quad.visible = false
	add_child(_quad)
	_surf_active = false


func _resize_surface(sz):
	_surf_size = sz
	for vp in [_vp_a, _vp_b, _vp_c]:
		vp.size = sz
	for r in [_rect_b, _rect_c]:
		r.rect_position = Vector2.ZERO
		r.rect_size = sz


func _set_surface_active(a):
	if a == _surf_active:
		return
	_surf_active = a
	var mode = Viewport.UPDATE_ALWAYS if a else Viewport.UPDATE_DISABLED
	for vp in [_vp_a, _vp_b, _vp_c]:
		vp.render_target_update_mode = mode
	if a:
		_quad_delay = 3   # let all three cleared buffers render before showing the quad
	elif _quad != null:
		_quad.visible = false


func _proj_p11(cam, aspect):
	if cam.projection == Camera.PROJECTION_ORTHOGONAL:
		var h = cam.size
		if cam.keep_aspect != Camera.KEEP_HEIGHT:
			h = cam.size / aspect
		return 2.0 / h
	var t = tan(deg2rad(cam.fov) * 0.5)
	if cam.keep_aspect == Camera.KEEP_HEIGHT:
		return 1.0 / t
	return aspect / t


func _update_surface():
	if _vp_a == null or _cam == null or not is_instance_valid(_cam):
		return
	var cvp = _cam.get_viewport()
	if cvp == null:
		return
	var full = cvp.size
	if full.x < 1.0 or full.y < 1.0:
		return
	var sz = Vector2(max(1.0, round(full.x * surface_resolution)), max(1.0, round(full.y * surface_resolution)))
	if sz != _surf_size:
		_resize_surface(sz)

	# Mirror the real camera into the hidden fluid viewport.
	var ct = _cam.global_transform
	_fcam.global_transform = ct
	_fcam.projection = _cam.projection
	_fcam.keep_aspect = _cam.keep_aspect
	_fcam.fov = _cam.fov
	_fcam.size = _cam.size
	_fcam.near = _cam.near
	_fcam.far = _cam.far
	_fcam.h_offset = _cam.h_offset
	_fcam.v_offset = _cam.v_offset

	var origin = ct.origin
	var fwd = -ct.basis.z.normalized()
	var cam_x = ct.basis.x.normalized()
	var cam_y = ct.basis.y.normalized()
	var near = max(_cam.near, 0.001)
	var far = _cam.far
	var drange = min(far, 4000.0)

	# Is any of the fluid in front of the camera?
	var active = false
	var dist = 0.0
	if _bounds_valid:
		var center = (_bmin + _bmax) * 0.5
		var ext = (_bmax - _bmin) * 0.5
		dist = (center - origin).dot(fwd)
		var reach = abs(fwd.x) * ext.x + abs(fwd.y) * ext.y + abs(fwd.z) * ext.z
		active = (dist + reach) > near and (dist - reach) < far
	if active:
		_inactive_frames = 0
		_set_surface_active(true)
	else:
		# Fast camera turns can briefly push the fluid out of view. Keep the buffers alive for a
		# few frames so coming back doesn't blank the surface while they re-initialise.
		_inactive_frames += 1
		if _inactive_frames > 12:
			_set_surface_active(false)
		return

	var aspect = full.x / full.y
	var ortho = _cam.projection == Camera.PROJECTION_ORTHOGONAL
	var p11 = _proj_p11(_cam, aspect)
	var blur_world = particle_size * surface_smoothing
	var sigma = max(particle_size * 0.5 * visual_scale * 1.5, 0.005)

	_mat_a.set_shader_param("depth_range", drange)
	for m in [_mat_b, _mat_c]:
		m.set_shader_param("tex_size", sz)
		m.set_shader_param("depth_range", drange)
		m.set_shader_param("guess_depth", max(dist, near))
		m.set_shader_param("blur_world", blur_world)
		m.set_shader_param("p11", p11)
		m.set_shader_param("ortho", ortho)
		m.set_shader_param("depth_sigma", sigma)

	_mat_q.set_shader_param("tex_size", sz)
	_mat_q.set_shader_param("depth_range", drange)
	_mat_q.set_shader_param("threshold", surface_threshold)
	_mat_q.set_shader_param("flip_y", surface_flip_y)
	_mat_q.set_shader_param("debug_mode", surface_debug)
	_mat_q.set_shader_param("fluid_color", Color(color.r, color.g, color.b, 1.0))
	_mat_q.set_shader_param("opacity", opacity)
	_mat_q.set_shader_param("rough", roughness)
	_mat_q.set_shader_param("spec", specular)
	_mat_q.set_shader_param("rim_alpha", rim_opacity)
	_mat_q.set_shader_param("emit_color", emission_color)
	_mat_q.set_shader_param("emit_energy", emission_energy)

	# Place a view-aligned quad through the middle of the fluid. Its pixels only supply the
	# view direction for lighting; the real depth is written by the shader.
	_quad.global_transform = _quad_xform(ct, aspect, ortho)

	if _quad_delay > 0:
		_quad_delay -= 1
		_quad.visible = false
	else:
		_quad.visible = true


func _quad_xform(ct, aspect, ortho):
	var origin = ct.origin
	var fwd = -ct.basis.z.normalized()
	var cam_x = ct.basis.x.normalized()
	var cam_y = ct.basis.y.normalized()
	var near = max(_cam.near, 0.001)
	var far = _cam.far
	var dist = ((_bmin + _bmax) * 0.5 - origin).dot(fwd)
	var qd = clamp(dist, near * 1.5, far * 0.95)
	var half_w
	var half_h
	if ortho:
		half_h = _cam.size * 0.5
		if _cam.keep_aspect != Camera.KEEP_HEIGHT:
			half_h = _cam.size * 0.5 / aspect
		half_w = half_h * aspect
	else:
		var t = tan(deg2rad(_cam.fov) * 0.5)
		if _cam.keep_aspect == Camera.KEEP_HEIGHT:
			half_h = qd * t
			half_w = half_h * aspect
		else:
			half_w = qd * t
			half_h = half_w / aspect
	half_w *= 1.4
	half_h *= 1.4
	return Transform(Basis(cam_x * half_w, cam_y * half_h, ct.basis.z.normalized()), origin + fwd * qd)


# Runs right before the frame is drawn (VisualServer.frame_pre_draw). Nodes that move the camera
# later in the frame than this emitter's _process would otherwise leave the hidden camera and the
# screen quad one frame behind, and fast camera movement then pushes the fluid out of the lagged
# quad / texture so it vanishes. Pushing the transforms straight to the VisualServer applies
# them to this very frame.
func _late_sync():
	if not _surface_on or not _surf_active or not _bounds_valid:
		return
	if _quad == null or _fcam == null or not is_instance_valid(_quad) or not is_instance_valid(_fcam):
		return
	if _cam == null or not is_instance_valid(_cam) or not _cam.is_inside_tree():
		return
	var cvp = _cam.get_viewport()
	if cvp == null or cvp.size.x < 1.0 or cvp.size.y < 1.0:
		return
	var aspect = cvp.size.x / cvp.size.y
	var ortho = _cam.projection == Camera.PROJECTION_ORTHOGONAL
	var ct = _cam.global_transform
	VisualServer.camera_set_transform(_fcam.get_camera_rid(), ct)
	VisualServer.instance_set_transform(_quad.get_instance(), _quad_xform(ct, aspect, ortho))


# --- Preset dropdown (editor only, never saved) -----------------------------

func _get_property_list():
	return [{"name": "preset", "type": TYPE_INT, "hint": PROPERTY_HINT_ENUM,
		"hint_string": PRESET_NAMES, "usage": PROPERTY_USAGE_EDITOR}]


func _get(property):
	if property == "preset":
		return _preset_shown
	return null


func _set(property, value):
	if property == "preset":
		_preset_shown = value
		if value > 0 and PRESETS.has(value):
			for k in PRESET_RESET:
				set(k, PRESET_RESET[k])
			var p = PRESETS[value]
			for k in p:
				set(k, p[k])
			property_list_changed_notify()
			_on_stream_changed()
		return true
	return false
