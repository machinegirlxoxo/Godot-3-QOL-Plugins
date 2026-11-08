tool
class_name CinematicDirector
extends Node
# Lives in your scene (added by the Cinematic tab) and plays the cutscenes stored in its child
# AnimationPlayer. The cutscene animations drive three properties of this node:
#   active_camera  which Camera is current (camera cuts)
#   subtitle       the subtitle text shown on screen
#   shake          camera shake strength
#   shakify        Shakify strength (handheld camera motion, like Blender's Camera Shakify)
#   shakify_setup  [preset, scale, speed] used by Shakify
#
# Audio (voice lines) is played by AudioStreamPlayer nodes that the cutscene's audio tracks point at
# (the Cinematic tab creates a "Voice" player under this node for you).
#
# From any script (autoload added by the plugin):  Cutscenes.start_cutscene("intro")  /  Cutscenes.end_cutscene()
# Or directly on this node:   $Cinematic.start_cutscene("intro")    # play a cutscene from its beginning
#                 $Cinematic.end_cutscene()              # stop it (skip); end_cutscene(true) jumps to its final state first
#                 or set Autoplay Cutscene in the Inspector
# Signals:        cutscene_started(name), cutscene_finished(name)  (finished is also sent when end_cutscene() is called)

signal cutscene_started(cutscene_name)
signal cutscene_finished(cutscene_name)

# Shakify presets. rot = degrees (pitch, yaw, roll), loc = metres (x, y, z), freq = how fast the
# organic wobble changes (Hz). step_* adds a walking / running bob: step_hz = footsteps per second.
const SHAKIFY_PRESETS = [
	{"name": "Handheld", "rot": Vector3(0.6, 0.6, 0.35), "loc": Vector3(0.010, 0.010, 0.008), "freq": 0.7,
		"step_hz": 0.0, "step_rot": Vector3(), "step_loc": Vector3()},
	{"name": "Breathing", "rot": Vector3(0.25, 0.15, 0.10), "loc": Vector3(0.002, 0.004, 0.002), "freq": 0.25,
		"step_hz": 0.0, "step_rot": Vector3(), "step_loc": Vector3()},
	{"name": "Walk", "rot": Vector3(0.7, 0.9, 0.5), "loc": Vector3(0.015, 0.02, 0.015), "freq": 0.8,
		"step_hz": 1.8, "step_rot": Vector3(0.6, 0.0, 0.5), "step_loc": Vector3(0.015, 0.025, 0.0)},
	{"name": "Jog", "rot": Vector3(1.2, 1.4, 0.9), "loc": Vector3(0.025, 0.03, 0.02), "freq": 1.0,
		"step_hz": 2.7, "step_rot": Vector3(1.2, 0.0, 0.8), "step_loc": Vector3(0.025, 0.05, 0.0)},
	{"name": "Run", "rot": Vector3(2.0, 2.2, 1.5), "loc": Vector3(0.04, 0.05, 0.03), "freq": 1.3,
		"step_hz": 3.3, "step_rot": Vector3(2.0, 0.0, 1.4), "step_loc": Vector3(0.04, 0.09, 0.0)},
	{"name": "Wobble (boat / drunk)", "rot": Vector3(1.5, 0.8, 3.0), "loc": Vector3(0.02, 0.03, 0.02), "freq": 0.35,
		"step_hz": 0.0, "step_rot": Vector3(), "step_loc": Vector3()},
	{"name": "Earthquake / impact", "rot": Vector3(2.5, 2.5, 2.0), "loc": Vector3(0.05, 0.05, 0.05), "freq": 6.0,
		"step_hz": 0.0, "step_rot": Vector3(), "step_loc": Vector3()},
]

export(String) var autoplay_cutscene = ""
export(bool) var show_subtitles = true
export(bool) var restore_camera = true     # when a cutscene ends, make the camera that was current before it current again (your player's camera)
export(Font) var subtitle_font
export(Color) var subtitle_color = Color(1, 1, 1)
export(float, 0.0, 5.0, 0.05) var shake_scale = 1.0
export(int) var shakify_seed = 1 setget set_shakify_seed
export(float, 0.0, 5.0, 0.05) var shakify_global_scale = 1.0

# Animated by the cutscene tracks. Not exported, so scrubbing in the editor is never saved.
var active_camera = NodePath("") setget set_active_camera
var subtitle = "" setget set_subtitle
var shake = 0.0
var shakify = 0.0 setget set_shakify
var shakify_setup = [] setget set_shakify_setup

const AUD_META = "cine_audio"      # per-audio-key Loop / length, written by the Cinematic tab

var _player: AnimationPlayer
var _prev_camera = null            # the camera that was current before the cutscene started
var _voice_watch = []              # looping voice lines that must be stopped at a given cutscene time
var _label: Label
var _camera: Camera
var _shake_time = 0.0
var _shake_dirty = false
var _noise: OpenSimplexNoise
var _sk_clock = 0.0
var _sk_cam: Camera
var _sk_base = Transform()
var _sk_applied = Transform()
var _sk_has = false


func _ready() -> void:
	_player = get_node_or_null("Player")
	if _player == null:
		for c in get_children():
			if c is AnimationPlayer:
				_player = c
				break
	if _player != null:
		_player.connect("animation_finished", self, "_on_animation_finished")
	if not Engine.editor_hint:
		_build_subtitle_ui()
		if autoplay_cutscene != "":
			play(autoplay_cutscene)


func play(cutscene_name: String = "") -> void:
	if _player != null:
		_capture_camera()
		_prepare_audio(cutscene_name)
		_player.play(cutscene_name)


# Starts the cutscene called `cutscene_name` from the beginning (restarts it if it is already running).
# Returns false if there is no cutscene with that name.
func start_cutscene(cutscene_name: String) -> bool:
	if _player == null or not _player.has_animation(cutscene_name):
		push_warning("CinematicDirector: no cutscene called '%s'." % cutscene_name)
		return false
	if _player.is_playing():
		end_cutscene(false, false)
	_capture_camera()
	_prepare_audio(cutscene_name)
	_player.play(cutscene_name)
	_player.seek(0.0, true)
	emit_signal("cutscene_started", cutscene_name)
	return true


# Ends the running cutscene now (e.g. when the player presses "skip").
# jump_to_end = true first applies the very last frame of the cutscene (final camera, final poses), so the
# game continues from where the cutscene would have ended. Emits cutscene_finished.
func end_cutscene(jump_to_end: bool = false, notify: bool = true) -> void:
	if _player == null:
		return
	var running = _player.current_animation
	if running == "":
		return
	if jump_to_end and _player.has_animation(running):
		_player.seek(_player.get_animation(running).length, true)
	_player.stop(false)
	_stop_voice(running)
	set_subtitle("")
	shake = 0.0
	shakify = 0.0
	_reset_shake()
	_restore_shakify()
	_voice_watch = []
	_restore_camera()
	if notify:
		emit_signal("cutscene_finished", running)


func has_cutscene(cutscene_name: String) -> bool:
	return _player != null and _player.has_animation(cutscene_name)


func get_cutscene_names() -> Array:
	var out = []
	if _player != null:
		for n in _player.get_animation_list():
			out.append(str(n))
	return out


func stop() -> void:
	if _player != null:
		var running = _player.current_animation
		_player.stop()
		_stop_voice(running)
	set_subtitle("")
	shake = 0.0
	shakify = 0.0
	_restore_shakify()
	_voice_watch = []
	_restore_camera()


# Remembers the camera the player was looking through, so it can be given back when the cutscene is over.
func _capture_camera() -> void:
	if Engine.editor_hint or not is_inside_tree() or is_playing():
		return
	var c = get_viewport().get_camera()
	if c != null:
		_prev_camera = c


func _restore_camera() -> void:
	var prev = _prev_camera
	_prev_camera = null
	if Engine.editor_hint or not restore_camera:
		return
	if prev != null and is_instance_valid(prev) and prev.is_inside_tree():
		set_active_camera(NodePath(""))
		prev.make_current()


# Before a cutscene starts: apply each audio key's Loop setting to its stream (on a copy, the imported file stays
# untouched) and remember the looping lines that have a length, so they can be stopped on time.
func _prepare_audio(cutscene_name: String) -> void:
	_voice_watch = []
	if Engine.editor_hint or _player == null or not _player.has_animation(cutscene_name):
		return
	var anim = _player.get_animation(cutscene_name)
	var base = _player.get_node_or_null(_player.root_node)
	var extras = {}
	if anim.has_meta(AUD_META):
		extras = anim.get_meta(AUD_META)
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_AUDIO:
			continue
		var list = extras.get(str(anim.track_get_path(i)), [])
		for k in range(anim.track_get_key_count(i)):
			var t = anim.track_get_key_time(i, k)
			var loop = false
			var dur = 0.0
			for x in list:
				if abs(x["t"] - t) < 0.0005:
					loop = bool(x["loop"])
					dur = float(x["dur"])
			var stream = anim.audio_track_get_key_stream(i, k)
			if stream != null:
				var fixed = _with_loop(stream, loop)
				if fixed != stream:
					anim.audio_track_set_key_stream(i, k, fixed)
			if loop and dur > 0.0 and base != null:
				var node = base.get_node_or_null(anim.track_get_path(i))
				if node != null:
					_voice_watch.append({"node": node, "stop_at": t + dur, "done": false})


func _with_loop(stream, loop: bool):
	if stream is AudioStreamSample:
		var want = AudioStreamSample.LOOP_FORWARD if loop else AudioStreamSample.LOOP_DISABLED
		if stream.loop_mode == want:
			return stream
		var d = stream.duplicate()
		d.loop_mode = want
		if loop and d.loop_end <= 0:
			var bytes = 1 if d.format == AudioStreamSample.FORMAT_8_BITS else 2
			if d.stereo:
				bytes *= 2
			d.loop_end = int(d.data.size() / bytes)
		return d
	var cur = stream.get("loop")
	if cur == null or bool(cur) == loop:
		return stream
	var d2 = stream.duplicate()
	d2.set("loop", loop)
	return d2


# Voice lines are normal AudioStreamPlayers started by the cutscene's audio tracks; stopping the animation
# alone would let them finish talking, so silence the ones this cutscene uses.
func _stop_voice(cutscene_name: String) -> void:
	if _player == null or not _player.has_animation(cutscene_name):
		return
	var base = _player.get_node_or_null(_player.root_node)
	if base == null:
		return
	var anim = _player.get_animation(cutscene_name)
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) == Animation.TYPE_AUDIO:
			var n = base.get_node_or_null(anim.track_get_path(i))
			if n != null and n.has_method("stop"):
				n.stop()


func is_playing() -> bool:
	return _player != null and _player.is_playing()


func get_player() -> AnimationPlayer:
	return _player


func get_active_camera_node() -> Camera:
	if str(active_camera) == "":
		return null
	var node = get_node_or_null(active_camera)
	return node if node is Camera else null


func set_active_camera(path) -> void:
	_restore_shakify()
	active_camera = path
	_reset_shake()
	_camera = get_active_camera_node()
	# The editor's own viewport must not be hijacked, so only switch cameras in the running game.
	if _camera != null and not Engine.editor_hint and _camera.is_inside_tree():
		_camera.make_current()


func set_subtitle(text) -> void:
	subtitle = str(text)
	if _label != null:
		_label.text = subtitle
		_label.visible = subtitle != ""


func _process(delta: float) -> void:
	if not _voice_watch.empty() and _player != null and _player.is_playing():
		var pos = _player.current_animation_position
		for w in _voice_watch:
			if not w["done"] and pos >= w["stop_at"]:
				w["done"] = true
				if is_instance_valid(w["node"]):
					w["node"].stop()
	if not Engine.editor_hint:
		_update_shakify(delta)
	if _camera == null or not is_instance_valid(_camera):
		return
	if shake > 0.001:
		_shake_time += delta * 30.0
		var s = shake * shake_scale * 0.05
		_camera.h_offset = (sin(_shake_time * 1.3) + sin(_shake_time * 2.9) * 0.5) * s
		_camera.v_offset = (cos(_shake_time * 1.7) + cos(_shake_time * 3.1) * 0.5) * s
		_shake_dirty = true
	elif _shake_dirty:
		_reset_shake()


func _reset_shake() -> void:
	if _camera != null and is_instance_valid(_camera):
		_camera.h_offset = 0.0
		_camera.v_offset = 0.0
	_shake_dirty = false


# ------------------------------------------------------------------ shakify

func set_shakify(v) -> void:
	shakify = float(v)


func set_shakify_setup(v) -> void:
	shakify_setup = v


func set_shakify_seed(v) -> void:
	shakify_seed = int(v)
	if _noise != null:
		_noise.seed = shakify_seed


func _get_noise() -> OpenSimplexNoise:
	if _noise == null:
		_noise = OpenSimplexNoise.new()
		_noise.seed = shakify_seed
		_noise.octaves = 3
		_noise.period = 1.0
		_noise.persistence = 0.5
	return _noise


func _n(x: float, axis: int) -> float:
	return clamp(_get_noise().get_noise_2d(x, float(axis) * 31.7) * 1.6, -1.0, 1.0)


# The handheld motion as an offset in the camera's own space (rotation + movement). `t` is the cutscene
# time in seconds; leave it out in the game and the director picks the time itself. Returns the identity
# when Shakify is off. The Cinematic tab uses this for the Result view, so scrubbing shows the shake too.
func get_shakify_offset(t = -1.0) -> Transform:
	if shakify <= 0.0005:
		return Transform()
	var idx = 0
	var sc = 1.0
	var sp = 1.0
	if shakify_setup is Array and shakify_setup.size() >= 3:
		idx = int(clamp(int(shakify_setup[0]), 0, SHAKIFY_PRESETS.size() - 1))
		sc = float(shakify_setup[1])
		sp = float(shakify_setup[2])
	var time = t
	if time < 0.0:
		time = _player.current_animation_position if (_player != null and _player.is_playing()) else _sk_clock
	time *= sp
	var p = SHAKIFY_PRESETS[idx]
	var k = shakify * sc * shakify_global_scale
	var f = time * p["freq"]
	var rot = Vector3(_n(f, 0) * p["rot"].x, _n(f, 1) * p["rot"].y, _n(f, 2) * p["rot"].z)
	var loc = Vector3(_n(f, 3) * p["loc"].x, _n(f, 4) * p["loc"].y, _n(f, 5) * p["loc"].z)
	if p["step_hz"] > 0.0:
		var ph = time * p["step_hz"] * TAU
		var sway = sin(ph * 0.5)               # side to side, once per two steps
		var bob = cos(ph)                      # up / down, once per step
		rot.x += sin(ph + 0.8) * p["step_rot"].x
		rot.z += sway * p["step_rot"].z
		loc.x += sway * p["step_loc"].x
		loc.y += bob * p["step_loc"].y
	rot *= k
	loc *= k
	var bs = Basis(Vector3(deg2rad(rot.x), deg2rad(rot.y), deg2rad(rot.z)))
	return Transform(bs, loc)


# In the running game the offset is applied to the real camera right after the AnimationPlayer has
# written its pose for the frame. If the animation did not touch the camera this frame (a static camera),
# our own offset from last frame is taken off first so the shake never builds up.
func _update_shakify(delta: float) -> void:
	_sk_clock += delta
	_restore_shakify()
	if shakify <= 0.0005:
		return
	var cam = _camera
	if cam == null or not is_instance_valid(cam):
		cam = get_viewport().get_camera() if get_viewport() != null else null
	if cam == null or not cam.is_inside_tree():
		return
	var off = get_shakify_offset()
	_sk_cam = cam
	_sk_base = cam.transform
	_sk_applied = _sk_base * off
	cam.transform = _sk_applied
	_sk_has = true


func _restore_shakify() -> void:
	if _sk_has and _sk_cam != null and is_instance_valid(_sk_cam):
		if _sk_cam.transform == _sk_applied:
			_sk_cam.transform = _sk_base
	_sk_has = false


func _on_animation_finished(anim_name) -> void:
	set_subtitle("")
	shake = 0.0
	shakify = 0.0
	_reset_shake()
	_stop_voice(str(anim_name))
	_voice_watch = []
	_restore_camera()
	emit_signal("cutscene_finished", anim_name)


func _build_subtitle_ui() -> void:
	if not show_subtitles:
		return
	var layer = CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_label = Label.new()
	_label.anchor_left = 0.1
	_label.anchor_right = 0.9
	_label.anchor_top = 0.80
	_label.anchor_bottom = 0.95
	_label.align = Label.ALIGN_CENTER
	_label.valign = Label.VALIGN_BOTTOM
	_label.autowrap = true
	_label.add_color_override("font_color", subtitle_color)
	_label.add_color_override("font_color_shadow", Color(0, 0, 0, 0.9))
	_label.add_constant_override("shadow_offset_x", 2)
	_label.add_constant_override("shadow_offset_y", 2)
	if subtitle_font != null:
		_label.add_font_override("font", subtitle_font)
	_label.visible = false
	layer.add_child(_label)
