tool
extends Spatial
# FluidStream: one jet / burst / squirt. Add it as a child of a FluidEmitter.
# The stream fires along its local -Z axis (the usual Godot "forward").
# Move / rotate this node to aim the nozzle. You can add several streams to one emitter.

const PRESET_NAMES = "Choose...,Squirt,Long Squirt,Steady Jet,Spray,Line Squirt,Long Line,Pulsed Line x3,Pulsed Line x5,Quick Pulses x6,Slow Dribble,Fan Spurt,Goo Line,Thick Goo Rope,Goo Splat,Long Goo Line"

# Every preset sets the same keys, so switching between them never leaves stale values behind.
const PRESETS = {
	1: {"count": 250, "duration": 0.35, "velocity": 4.5, "velocity_random": 0.0, "spread_degrees": 3.0, "nozzle_radius": 0.01,
		"vel_start": 0.6, "vel_peak_time": 0.15, "vel_peak": 1.0, "vel_end": 0.2,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	2: {"count": 450, "duration": 0.9, "velocity": 4.0, "velocity_random": 0.0, "spread_degrees": 3.0, "nozzle_radius": 0.01,
		"vel_start": 0.5, "vel_peak_time": 0.2, "vel_peak": 1.0, "vel_end": 0.25,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	3: {"count": 600, "duration": 1.5, "velocity": 4.0, "velocity_random": 0.0, "spread_degrees": 1.0, "nozzle_radius": 0.01,
		"vel_start": 1.0, "vel_peak_time": 0.5, "vel_peak": 1.0, "vel_end": 1.0,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	4: {"count": 400, "duration": 0.6, "velocity": 3.0, "velocity_random": 0.0, "spread_degrees": 15.0, "nozzle_radius": 0.02,
		"vel_start": 0.7, "vel_peak_time": 0.3, "vel_peak": 1.0, "vel_end": 0.4,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},

	# --- Line / pulse presets (best with the "Milky Rope" emitter preset) ---
	# One tight, fast, thin line that arcs under gravity.
	5: {"count": 380, "duration": 0.55, "velocity": 5.5, "velocity_random": 0.03, "spread_degrees": 0.6, "nozzle_radius": 0.006,
		"vel_start": 0.8, "vel_peak_time": 0.1, "vel_peak": 1.0, "vel_end": 0.35,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	# The same, but longer and steadier.
	6: {"count": 700, "duration": 1.1, "velocity": 6.0, "velocity_random": 0.03, "spread_degrees": 0.5, "nozzle_radius": 0.006,
		"vel_start": 0.85, "vel_peak_time": 0.15, "vel_peak": 1.0, "vel_end": 0.5,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	# Three separate lines in a row, each a bit weaker than the last.
	7: {"count": 600, "duration": 1.4, "velocity": 5.0, "velocity_random": 0.04, "spread_degrees": 0.8, "nozzle_radius": 0.007,
		"vel_start": 0.5, "vel_peak_time": 0.25, "vel_peak": 1.0, "vel_end": 0.4,
		"pulses": 3, "pulse_gap": 0.45, "pulse_decay": 0.8},
	# Five shorter lines, fading out.
	8: {"count": 700, "duration": 1.8, "velocity": 4.6, "velocity_random": 0.04, "spread_degrees": 1.0, "nozzle_radius": 0.007,
		"vel_start": 0.5, "vel_peak_time": 0.25, "vel_peak": 1.0, "vel_end": 0.35,
		"pulses": 5, "pulse_gap": 0.5, "pulse_decay": 0.85},
	# Six quick, small pulses.
	9: {"count": 480, "duration": 0.9, "velocity": 5.5, "velocity_random": 0.04, "spread_degrees": 1.2, "nozzle_radius": 0.007,
		"vel_start": 0.6, "vel_peak_time": 0.3, "vel_peak": 1.0, "vel_end": 0.4,
		"pulses": 6, "pulse_gap": 0.55, "pulse_decay": 0.88},
	# Slow, low-pressure flow that just drips out.
	10: {"count": 150, "duration": 1.5, "velocity": 1.6, "velocity_random": 0.05, "spread_degrees": 2.0, "nozzle_radius": 0.012,
		"vel_start": 0.6, "vel_peak_time": 0.3, "vel_peak": 1.0, "vel_end": 0.3,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	# A wider, shorter burst.
	11: {"count": 450, "duration": 0.5, "velocity": 4.8, "velocity_random": 0.08, "spread_degrees": 8.0, "nozzle_radius": 0.012,
		"vel_start": 0.7, "vel_peak_time": 0.15, "vel_peak": 1.0, "vel_end": 0.3,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},

	# --- Goo presets (best with the Sticky Goo / Slime Rope / Honey Glue / Clear Glue emitter presets) ---
	# Dense, perfectly straight launch so the line stays one connected strand.
	12: {"count": 900, "duration": 1.0, "velocity": 4.5, "velocity_random": 0.0, "spread_degrees": 0.3, "nozzle_radius": 0.006,
		"vel_start": 0.9, "vel_peak_time": 0.15, "vel_peak": 1.0, "vel_end": 0.7,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	13: {"count": 1100, "duration": 1.6, "velocity": 3.2, "velocity_random": 0.0, "spread_degrees": 0.5, "nozzle_radius": 0.012,
		"vel_start": 0.8, "vel_peak_time": 0.2, "vel_peak": 1.0, "vel_end": 0.6,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	14: {"count": 500, "duration": 0.35, "velocity": 6.0, "velocity_random": 0.0, "spread_degrees": 1.5, "nozzle_radius": 0.015,
		"vel_start": 0.7, "vel_peak_time": 0.1, "vel_peak": 1.0, "vel_end": 0.5,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
	15: {"count": 1400, "duration": 2.2, "velocity": 4.0, "velocity_random": 0.0, "spread_degrees": 0.3, "nozzle_radius": 0.006,
		"vel_start": 0.9, "vel_peak_time": 0.15, "vel_peak": 1.0, "vel_end": 0.8,
		"pulses": 1, "pulse_gap": 0.5, "pulse_decay": 1.0},
}

# --- Timing -----------------------------------------------------------------
# Seconds after the emitter starts before this stream begins.
export(float, 0.0, 30.0, 0.01) var start_delay = 0.0
# Seconds over which `count` particles are emitted.
export(float, 0.01, 30.0, 0.01) var duration = 0.5
# Total number of particles this stream emits.
export(int, 1, 20000) var count = 300
export(bool) var enabled = true

# --- Velocity ---------------------------------------------------------------
# Peak launch speed in meters per second.
export(float, 0.0, 100.0, 0.1) var velocity = 5.0
# Random +/- variation of the launch speed (0..1).
export(float, 0.0, 1.0, 0.01) var velocity_random = 0.0
# Cone angle of the jet in degrees.
export(float, 0.0, 90.0, 0.1) var spread_degrees = 2.0
# Radius of the nozzle opening in meters.
export(float, 0.0, 1.0, 0.001) var nozzle_radius = 0.01

# --- Pulses -----------------------------------------------------------------
# Split the stream into several separate bursts ("lines") with gaps in between.
# 1 = a single continuous stream (the gap and decay settings are ignored).
export(int, 1, 12) var pulses = 1
# Fraction of each pulse period that is silent (only used when pulses > 1).
export(float, 0.0, 0.95, 0.01) var pulse_gap = 0.5
# Each pulse is this much weaker (speed and particle count) than the previous one.
export(float, 0.2, 1.0, 0.01) var pulse_decay = 1.0

# --- Velocity curve (relative to `velocity`, over the stream's duration) ------
export(float, 0.0, 1.0, 0.01) var vel_start = 0.5
export(float, 0.01, 0.99, 0.01) var vel_peak_time = 0.2
export(float, 0.0, 1.0, 0.01) var vel_peak = 1.0
export(float, 0.0, 1.0, 0.01) var vel_end = 0.25
# Use a hand-drawn Curve instead of the start/peak/end values above.
# X axis = time through the stream (0..1), Y axis = speed multiplier (0..1).
export(bool) var use_custom_curve = false
export(Curve) var velocity_curve setget _set_curve

# --- Interaction ------------------------------------------------------------
# 0 = this stream's particles only interact with each other (fastest).
# 1 = also interacts with other streams on the same emitter that use this mode.
export(int, "Own stream only", "Other streams on emitter") var link = 0

var _preset_shown = 0


func _is_fluid_stream():
	return true


func get_speed_at(t):
	t = clamp(t, 0.0, 1.0)
	var m
	if use_custom_curve and velocity_curve != null:
		m = velocity_curve.interpolate(t)
	elif t < vel_peak_time:
		m = lerp(vel_start, vel_peak, _smooth(t / vel_peak_time))
	else:
		m = lerp(vel_peak, vel_end, _smooth((t - vel_peak_time) / max(0.0001, 1.0 - vel_peak_time)))
	return velocity * max(0.0, m)


func _active_frac():
	if pulses <= 1:
		return 1.0
	return 1.0 - pulse_gap


# Relative weight of every pulse, and their sum.
func _weights():
	var w = []
	var total = 0.0
	var cur = 1.0
	for _i in range(int(max(1, pulses))):
		w.append(cur)
		total += cur
		cur *= pulse_decay
	return [w, total]


# Fraction (0..1) of this stream's particles that should exist at normalized time tn (0..1).
func emitted_fraction(tn):
	tn = clamp(tn, 0.0, 1.0)
	var np = int(max(1, pulses))
	if np == 1:
		return tn
	var wt = _weights()
	var w = wt[0]
	var total = wt[1]
	var act = _active_frac() / np
	var cum = 0.0
	for i in range(np):
		var s0 = float(i) / np
		if tn >= s0 + act:
			cum += w[i] / total
		elif tn > s0:
			cum += (w[i] / total) * (tn - s0) / act
			break
		else:
			break
	return cum


# For the particle at fraction u (0..1) of the stream: returns Vector2(normalized emit time, launch speed).
func sample(u):
	u = clamp(u, 0.0, 0.999999)
	var np = int(max(1, pulses))
	if np == 1:
		return Vector2(u, get_speed_at(u))
	var wt = _weights()
	var w = wt[0]
	var total = wt[1]
	var c = 0.0
	var idx = np - 1
	var local = 1.0
	for i in range(np):
		var f = w[i] / total
		if u < c + f or i == np - 1:
			idx = i
			local = clamp((u - c) / f, 0.0, 1.0)
			break
		c += f
	var t = (float(idx) + local * _active_frac()) / np
	return Vector2(t, get_speed_at(local) * pow(pulse_decay, idx))


func _smooth(x):
	x = clamp(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


var _last_signature = []


func _ready():
	# In the editor, watch for inspector edits so the emitter can re-run its preview.
	set_process(Engine.editor_hint)
	_last_signature = _signature()
	if velocity_curve != null:
		_watch_curve(velocity_curve)


func _process(_delta):
	var sig = _signature()
	if sig != _last_signature:
		_last_signature = sig
		_changed()


func _signature():
	return [enabled, count, start_delay, duration, velocity, velocity_random, spread_degrees,
		nozzle_radius, vel_start, vel_peak_time, vel_peak, vel_end, use_custom_curve, link,
		pulses, pulse_gap, pulse_decay]
	# NOTE: global_transform is deliberately NOT part of the signature. Moving / rotating the
	# stream (animation, BoneAttachment, parent movement) must not restart the effect: every
	# particle reads the stream's current transform when it is spawned, so the nozzle simply
	# follows the node while the simulation keeps playing.


func _changed():
	update_configuration_warning()
	var p = get_parent()
	if p != null and p.has_method("_on_stream_changed"):
		p._on_stream_changed()


func _set_curve(v):
	if velocity_curve != null and velocity_curve.is_connected("changed", self, "_changed"):
		velocity_curve.disconnect("changed", self, "_changed")
	velocity_curve = v
	if v != null:
		_watch_curve(v)
	_changed()


func _watch_curve(c):
	if not c.is_connected("changed", self, "_changed"):
		c.connect("changed", self, "_changed")


func _get_configuration_warning():
	var p = get_parent()
	if p == null or not p.has_method("_is_fluid_emitter"):
		return "A FluidStream must be a child of a FluidEmitter."
	return ""


# --- Preset dropdown (editor only, never saved, so it can't overwrite your values) ---
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
			var p = PRESETS[value]
			for k in p:
				set(k, p[k])
			_changed()
			property_list_changed_notify()
		return true
	return false
