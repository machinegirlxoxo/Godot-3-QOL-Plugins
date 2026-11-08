extends Node
# Autoload "Cutscenes" (added automatically when the Cinematic Editor plugin is enabled).
# Start or end a cutscene from ANY script, without needing a reference to the Cinematic node:
#
#   Cutscenes.start_cutscene("intro")      # plays the cutscene called "intro" from its beginning
#   Cutscenes.end_cutscene()               # ends the running cutscene now (e.g. a "skip" button)
#   Cutscenes.end_cutscene(true)           # same, but first jumps to the cutscene's final frame
#
#   Cutscenes.finished                     # bool: true when no cutscene is running (it ran out or was ended),
#                                          # false from start_cutscene() until it is over.  Starts as true.
#   Cutscenes.is_playing()                 # true while a cutscene runs
#   Cutscenes.get_current_cutscene()       # name of the running cutscene ("" if none)
#   Cutscenes.cutscene_finished            # signal(cutscene_name): it ran out OR was ended
#   Cutscenes.cutscene_started             # signal(cutscene_name)
#
# It looks for the Cinematic node in the running scene and uses the one that owns a cutscene with that name.
#
# A cutscene that lives in ANOTHER scene file (a cutscene package from "Save cutscene package...", or any scene
# with a Cinematic node in it) can be played from whatever scene you are in:
#
#   Cutscenes.start_cutscene_from("res://cutscenes/intro.tscn")                 # plays its cutscene
#   Cutscenes.start_cutscene_from("res://cutscenes/intro.tscn", "intro")        # pick the cutscene by name
#   Cutscenes.start_cutscene_from("res://stage.tscn", "intro", null, Vector3(0, 500, 0))   # place it elsewhere
#
# The scene is added on top of the current one (nothing of the current scene is lost: the player keeps its place),
# the cutscene plays, the camera goes back to the player, and the added scene is removed again when it ends.
# Or register a name once and then use the normal call from anywhere:
#
#   Cutscenes.register_cutscene("intro", "res://cutscenes/intro.tscn")
#   Cutscenes.start_cutscene("intro")

const DirectorScript = preload("res://addons/cinematic_editor/cinematic_director.gd")

signal cutscene_started(cutscene_name)
signal cutscene_finished(cutscene_name)

# true = nothing is running (the last cutscene finished or was ended); false while a cutscene started by
# start_cutscene() is running. Handy for:   yield(Cutscenes, "cutscene_finished")   or   if Cutscenes.finished:
var finished = true

var _active = null       # the Cinematic node that is playing right now
var _registry = {}       # cutscene name -> scene file that holds it
var _spawned = {}        # Cinematic node -> the scene instance that was added just for its cutscene


# Starts the cutscene `cutscene_name` from the beginning. Returns false when no Cinematic node has it.
# `search_root` (optional) limits the search to one part of the tree.
func start_cutscene(cutscene_name: String, search_root: Node = null) -> bool:
	var director = _find_director(cutscene_name, search_root)
	if director == null and search_root == null and _registry.has(cutscene_name):
		return start_cutscene_from(str(_registry[cutscene_name]), cutscene_name)
	if director == null:
		push_warning("Cutscenes: no Cinematic node with a cutscene called '%s' was found in the running scene." % cutscene_name)
		return false
	if _active != null and is_instance_valid(_active) and _active != director:
		_active.end_cutscene(false, true)
	_active = director
	if not director.is_connected("cutscene_started", self, "_on_started"):
		director.connect("cutscene_started", self, "_on_started")
	if not director.is_connected("cutscene_finished", self, "_on_finished"):
		director.connect("cutscene_finished", self, "_on_finished")
	finished = false
	var ok = director.start_cutscene(cutscene_name)
	if not ok:
		finished = true
	return ok


# Tells the autoload which scene file holds a cutscene, so start_cutscene("name") works from any scene.
func register_cutscene(cutscene_name: String, scene_path: String) -> void:
	_registry[cutscene_name] = scene_path


# Plays a cutscene that is stored in another scene file. The scene is added as a child of `parent` (default: the
# running scene), `origin` (a Transform or a Vector3) places it if it is a 3D scene, and it is removed again when
# the cutscene is over. cutscene_name "" = the package's own cutscene (or the first one in the scene).
func start_cutscene_from(scene_path: String, cutscene_name: String = "", parent: Node = null, origin = null) -> bool:
	var packed = load(scene_path)
	if not (packed is PackedScene):
		push_warning("Cutscenes: '%s' is not a scene." % scene_path)
		return false
	var inst = packed.instance()
	if inst is Spatial:
		if origin is Transform:
			inst.transform = origin
		elif origin is Vector3:
			inst.translation = origin
	var host = parent
	if host == null:
		host = get_tree().current_scene
	if host == null:
		host = get_tree().root
	host.add_child(inst)
	var found = []
	_collect(inst, found)
	var cname = cutscene_name
	if not found.empty() and cname == "":
		if inst.has_meta("cinematic_package"):
			cname = str(inst.get_meta("cinematic_package").get("cutscene", ""))
		if cname == "" or not found[0].has_cutscene(cname):
			var names = found[0].get_cutscene_names()
			cname = names[0] if not names.empty() else ""
	var director = null
	for d in found:
		if d.has_cutscene(cname):
			director = d
			break
	if director == null:
		push_warning("Cutscenes: '%s' has no Cinematic node with a cutscene called '%s'." % [scene_path, cname])
		inst.queue_free()
		return false
	_spawned[director] = inst
	if not start_cutscene(cname, inst):
		_spawned.erase(director)
		inst.queue_free()
		return false
	return true


# Ends the running cutscene. jump_to_end = true applies its last frame first (final camera / poses).
func end_cutscene(jump_to_end: bool = false) -> void:
	if _active != null and is_instance_valid(_active):
		_active.end_cutscene(jump_to_end)


func is_playing() -> bool:
	return _active != null and is_instance_valid(_active) and _active.is_playing()


func get_current_cutscene() -> String:
	if not is_playing():
		return ""
	var p = _active.get_player()
	return str(p.current_animation) if p != null else ""


func _on_started(cutscene_name) -> void:
	finished = false
	emit_signal("cutscene_started", cutscene_name)


func _on_finished(cutscene_name) -> void:
	finished = true
	if _active != null and _spawned.has(_active):       # a scene that was added just for this cutscene: remove it
		var inst = _spawned[_active]
		_spawned.erase(_active)
		if is_instance_valid(inst):
			inst.queue_free()
	emit_signal("cutscene_finished", cutscene_name)


func _find_director(cutscene_name: String, search_root: Node):
	var root = search_root if search_root != null else get_tree().root
	var found = []
	_collect(root, found)
	for d in found:
		if d.has_cutscene(cutscene_name):
			return d
	return null


func _collect(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c.get_script() == DirectorScript:
			out.append(c)
		_collect(c, out)
