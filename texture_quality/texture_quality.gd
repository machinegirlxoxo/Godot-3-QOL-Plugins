extends Node
# Autoload singleton "TextureQuality".
#
# Quality level 0 = best baked tier, 1 = one tier lower, and so on.
# A VRAM budget (MB, 0 = unlimited) is enforced on top of the quality level:
# if the textures at the requested quality don't fit, the biggest / lowest
# priority ones are stepped down until they do.

const StreamedTexScript = preload("res://addons/texture_quality/streamed_tex.gd")

signal tier_changed(key, tier)
signal settled()

const MB = 1048576.0
const USER_CFG = "user://texture_quality.cfg"


class Entry:
	var key = ""
	var tiers = []        # [{path, w, h, bytes}], index 0 = best quality
	var flags = 7
	var textures = []     # WeakRefs to StreamedTex instances using this key
	var current = -1      # tier currently uploaded
	var target = 0        # tier we want after quality + budget
	var loading = -1      # tier being loaded in the background
	var priority = 1.0    # higher = keeps quality longer when over budget
	var score = 0.0
	var lod_tier = -1     # distance LOD: -1 = not measured yet, -2 = no 3D user found, >= 0 = tier wanted for its distance


# ---- distance LOD (see the README): the closer a texture's nearest mesh is to the camera, the better tier it gets.
# near_distance or closer = best tier, far_distance or farther = smallest tier, linear steps in between.
# The global quality level is the ceiling: LOD never gives a texture a better tier than the quality level allows.
var lod_enabled = true
var near_distance = 5.0
var far_distance = 60.0
var lod_nodes_per_frame = 128     # meshes measured per frame

var max_swaps_per_frame = 4   # GPU uploads applied per frame (avoids hitches)

var _entries = {}
var _max_tier = 0
var _quality = 0
var _budget = 0               # bytes, 0 = unlimited
var _over_budget = false
var _dirty = true
var _need_schedule = false
var _pending = false
var _was_pending = false

var _thread = null
var _sem = Semaphore.new()
var _mutex = Mutex.new()
var _jobs = []
var _done = []
var _exit = false

var _users = []                   # weakrefs to MeshInstance / Sprite3D nodes whose textures are measured
var _scan_index = 0
var _dist_new = {}                # texture key -> nearest distance seen during the running pass
var _lod_unmeasured = false
var _pass_nodes = 0               # nodes measured in the running pass (had a camera)
var _pass_managed = 0             # ... of which use a Texture Quality texture
var _empty_passes = 0
var _last_note = ""
var _lod_wait = 0.0               # short pause between two passes


func _ready() -> void:
	if ProjectSettings.has_setting("texture_quality/quality"):
		_quality = int(ProjectSettings.get_setting("texture_quality/quality"))
	if ProjectSettings.has_setting("texture_quality/vram_budget_mb"):
		_budget = int(float(ProjectSettings.get_setting("texture_quality/vram_budget_mb")) * MB)
	if ProjectSettings.has_setting("texture_quality/max_swaps_per_frame"):
		max_swaps_per_frame = int(ProjectSettings.get_setting("texture_quality/max_swaps_per_frame"))
	if ProjectSettings.has_setting("texture_quality/distance_lod"):
		lod_enabled = bool(ProjectSettings.get_setting("texture_quality/distance_lod"))
	if ProjectSettings.has_setting("texture_quality/near_distance"):
		near_distance = float(ProjectSettings.get_setting("texture_quality/near_distance"))
	if ProjectSettings.has_setting("texture_quality/far_distance"):
		far_distance = float(ProjectSettings.get_setting("texture_quality/far_distance"))
	if ProjectSettings.has_setting("texture_quality/lod_nodes_per_frame"):
		lod_nodes_per_frame = int(ProjectSettings.get_setting("texture_quality/lod_nodes_per_frame"))
	# Settings saved from a script (save_quality) win over the project settings.
	var cfg = ConfigFile.new()
	if cfg.load(USER_CFG) == OK:
		if cfg.has_section_key("texture_quality", "quality"):
			_quality = int(cfg.get_value("texture_quality", "quality"))
		if cfg.has_section_key("texture_quality", "vram_budget_mb"):
			_budget = int(float(cfg.get_value("texture_quality", "vram_budget_mb")) * MB)
		if cfg.has_section_key("texture_quality", "distance_lod"):
			lod_enabled = bool(cfg.get_value("texture_quality", "distance_lod"))
		if cfg.has_section_key("texture_quality", "near_distance"):
			near_distance = float(cfg.get_value("texture_quality", "near_distance"))
		if cfg.has_section_key("texture_quality", "far_distance"):
			far_distance = float(cfg.get_value("texture_quality", "far_distance"))
	get_tree().connect("node_added", self, "_on_node_added")
	_track_subtree(get_tree().root)
	_thread = Thread.new()
	_thread.start(self, "_worker")
	if OS.is_debug_build():
		print("TextureQuality: running, quality level %d, budget %d MB. Keys: [ lower quality, ] raise quality." % [_quality, int(_budget / MB)])


func _unhandled_input(event) -> void:
	if not OS.is_debug_build() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if ProjectSettings.has_setting("texture_quality/debug_hotkeys") and not bool(ProjectSettings.get_setting("texture_quality/debug_hotkeys")):
		return
	var level = int(min(_quality, _max_tier))
	if event.scancode == KEY_BRACKETLEFT:
		set_quality(min(level + 1, _max_tier))
		print("TextureQuality: quality level %d (0 = best)" % _quality)
	elif event.scancode == KEY_BRACKETRIGHT:
		set_quality(max(level - 1, 0))
		print("TextureQuality: quality level %d (0 = best)" % _quality)


func _exit_tree() -> void:
	if _thread != null:
		_exit = true
		_sem.post()
		_thread.wait_to_finish()
		_thread = null


# ------------------------------------------------------------------ public API

# Saves the quality level (0 = best) to user://texture_quality.cfg. It is used the next time
# the game starts. Call restart_game() afterwards, or use set_quality_and_restart().
func save_quality(level: int) -> void:
	_write_user_setting("quality", int(max(0, level)))


# Same for the VRAM budget in MB (0 = unlimited).
func save_vram_budget_mb(mb: float) -> void:
	_write_user_setting("vram_budget_mb", max(0.0, mb))


func set_quality_and_restart(level: int) -> void:
	save_quality(level)
	restart_game()


# Starts a new instance of the game and quits this one.
func restart_game() -> void:
	OS.execute(OS.get_executable_path(), OS.get_cmdline_args(), false)
	get_tree().quit()


# Removes everything saved by save_quality / save_vram_budget_mb.
func clear_saved_settings() -> void:
	var dir = Directory.new()
	if dir.file_exists(USER_CFG):
		dir.remove(USER_CFG)


func _write_user_setting(key: String, value) -> void:
	var cfg = ConfigFile.new()
	cfg.load(USER_CFG)
	cfg.set_value("texture_quality", key, value)
	cfg.save(USER_CFG)


# Distance LOD. near = best tier at or below this distance, far = smallest tier at or beyond it (world units).
func set_distance_range(near: float, far: float) -> void:
	near_distance = max(0.0, near)
	far_distance = max(far, near_distance + 0.01)
	_lod_wait = 0.0       # re-measure right away


func set_distance_lod_enabled(enabled: bool) -> void:
	lod_enabled = enabled
	_scan_index = 0
	_dist_new = {}
	if enabled:
		for e in _entries.values():
			e.lod_tier = -1
		_lod_unmeasured = true
	_dirty = true


func is_distance_lod_enabled() -> bool:
	return lod_enabled


func get_near_distance() -> float:
	return near_distance


func get_far_distance() -> float:
	return far_distance


# Saves the distance range to user://texture_quality.cfg (used the next time the game starts).
func save_distance_range(near: float, far: float) -> void:
	_write_user_setting("near_distance", max(0.0, near))
	_write_user_setting("far_distance", max(far, near + 0.01))


func set_quality(level: int) -> void:
	_quality = int(max(0, level))
	_dirty = true


func get_quality() -> int:
	return _quality


func get_max_quality_level() -> int:
	return _max_tier


func set_vram_budget_mb(mb: float) -> void:
	_budget = int(max(0.0, mb) * MB)
	_dirty = true


func get_vram_budget_mb() -> float:
	return _budget / MB


# Estimated VRAM held by managed textures right now / once all swaps finish.
func get_managed_vram_mb() -> float:
	var total = 0
	for e in _entries.values():
		total += _cost(e, e.current)
	return total / MB


func get_target_vram_mb() -> float:
	var total = 0
	for e in _entries.values():
		total += _cost(e, e.target)
	return total / MB


# True when even the lowest baked tiers don't fit in the budget.
func is_over_budget() -> bool:
	return _over_budget


# Whatever the engine reports for all textures (not only managed ones).
func get_engine_texture_mem_mb() -> float:
	return VisualServer.get_render_info(VisualServer.INFO_TEXTURE_MEM_USED) / MB


func set_priority(key: String, priority: float) -> void:
	if _entries.has(key):
		_entries[key].priority = priority
		_dirty = true


func get_tier(key: String) -> int:
	return _entries[key].current if _entries.has(key) else -1


func is_settled() -> bool:
	return not _pending and not _dirty


# Called by StreamedTex. The imported texture already holds its smallest tier,
# so nothing is loaded here; the solver upgrades it in the background.
func register_texture(tex) -> void:
	var key = tex.source_path
	if key == "" or tex.tiers.empty():
		push_warning("TextureQuality: texture '%s' has no baked tiers." % key)
		return
	var e = _entries.get(key)
	if e == null:
		e = Entry.new()
		e.key = key
		e.flags = int(tex.streamed_flags)
		e.priority = float(tex.priority)
		for t in tex.tiers:
			e.tiers.append({"path": t["path"], "w": int(t["w"]), "h": int(t["h"]), "bytes": int(t["bytes"])})
		e.current = e.tiers.size() - 1
		_entries[key] = e
		_lod_unmeasured = true
		_max_tier = int(max(_max_tier, e.tiers.size() - 1))
		e.textures.append(weakref(tex))
	else:
		e.textures.append(weakref(tex))
		if e.current != e.tiers.size() - 1:
			var img = load(e.tiers[e.current]["path"])
			if img is Image:
				_upload(e, tex, img)
	_dirty = true


# ------------------------------------------------------------------- internals

func _cost(e, tier: int) -> int:
	if tier < 0:
		return 0
	return e.tiers[tier]["bytes"] * int(max(e.textures.size(), 1))


func _upload(e, tex, img) -> void:
	tex.create_from_image(img, e.flags)
	tex.set_size_override(Vector2(e.tiers[0]["w"], e.tiers[0]["h"]))


func _process(_delta) -> void:
	_lod_step(_delta)
	_apply_done()
	if _dirty:
		_dirty = false
		_solve()
		_need_schedule = true
	if _need_schedule:
		_need_schedule = false
		_pending = _schedule()
		if _was_pending and not _pending:
			emit_signal("settled")
			if OS.is_debug_build():
				print("TextureQuality: settled, %d textures managed, %.1f MB" % [_entries.size(), get_managed_vram_mb()])
		_was_pending = _pending


func _prune() -> void:
	var dead = []
	for key in _entries:
		var e = _entries[key]
		var alive = []
		for w in e.textures:
			if w.get_ref() != null:
				alive.append(w)
		e.textures = alive
		if alive.empty():
			dead.append(key)
	for key in dead:
		_entries.erase(key)


func _cmp_score(a, b) -> bool:
	return a.score > b.score


func _cmp_priority(a, b) -> bool:
	return a.priority > b.priority


# Decide target tier for every entry: quality level first, then budget.
func _solve() -> void:
	_prune()
	var list = _entries.values()
	var total = 0
	for e in list:
		var last = e.tiers.size() - 1
		var t = int(clamp(_quality, 0, last))
		if lod_enabled:
			if e.lod_tier == -1:
				t = last                                  # not measured yet: stay on the tier it already holds
			elif e.lod_tier >= 0:
				t = int(max(t, min(e.lod_tier, last)))    # quality level is the ceiling, distance can only lower it
		e.target = t
		total += _cost(e, e.target)
	_over_budget = false
	if _budget > 0:
		while total > _budget:
			var cand = []
			for e in list:
				if e.target < e.tiers.size() - 1:
					e.score = float(_cost(e, e.target)) / max(e.priority, 0.001)
					cand.append(e)
			if cand.empty():
				_over_budget = true
				break
			cand.sort_custom(self, "_cmp_score")
			for e in cand:
				total -= _cost(e, e.target)
				e.target += 1
				total += _cost(e, e.target)
				if total <= _budget:
					break


# Start background loads. Downgrades first (they free memory); upgrades only
# when they fit under the budget. Returns true while work remains.
func _schedule() -> bool:
	var list = _entries.values()
	var peak = 0
	for e in list:
		var tier = e.current
		if e.loading != -1 and e.loading < e.current:
			tier = e.loading
		peak += _cost(e, tier)
	var ups = []
	var pending = false
	for e in list:
		if e.loading != -1:
			pending = true
			continue
		if e.current == e.target:
			continue
		pending = true
		if e.target > e.current:
			_queue_job(e, e.target)
		else:
			ups.append(e)
	ups.sort_custom(self, "_cmp_priority")
	for e in ups:
		var delta = _cost(e, e.target) - _cost(e, e.current)
		if _budget > 0 and peak + delta > _budget:
			continue
		_queue_job(e, e.target)
		peak += delta
	return pending


func _queue_job(e, tier: int) -> void:
	e.loading = tier
	_mutex.lock()
	_jobs.append({"key": e.key, "tier": tier, "path": e.tiers[tier]["path"]})
	_mutex.unlock()
	_sem.post()


# ------------------------------------------------------------------ distance LOD

func _on_node_added(n: Node) -> void:
	if (n is MeshInstance or n is Sprite3D) and not n.has_meta("tq_tracked"):
		n.set_meta("tq_tracked", true)
		_users.append(weakref(n))


func _track_subtree(n: Node) -> void:
	_on_node_added(n)
	for c in n.get_children():
		_track_subtree(c)


# Measures a slice of the tracked nodes every frame; after the last one the tiers are re-decided.
# Every node is measured from the camera of the viewport it lives in, so a 3D world inside a
# Viewport / ViewportContainer works as well as one in the main window.
func _lod_step(delta: float) -> void:
	if not lod_enabled:
		return
	if _lod_wait > 0.0:
		_lod_wait -= delta
		return
	if _users.empty() and not _lod_unmeasured:
		return
	var cams = {}                                   # viewport -> [has camera, camera position], this frame
	var budget = int(max(lod_nodes_per_frame, 1))
	while budget > 0 and _scan_index < _users.size():
		budget -= 1
		var node = _users[_scan_index].get_ref()
		_scan_index += 1
		if node == null or not node.is_inside_tree():
			continue
		var vp = node.get_viewport()
		if vp == null:
			continue
		if not cams.has(vp):
			var cam = vp.get_camera()
			cams[vp] = [cam != null, cam.global_transform.origin if cam != null else Vector3()]
		if not cams[vp][0]:
			continue
		_pass_nodes += 1
		_measure(node, cams[vp][1])
	if _scan_index >= _users.size():
		_finish_pass()


func _finish_pass() -> void:
	_scan_index = 0
	var alive = []
	for w in _users:
		if w.get_ref() != null:
			alive.append(w)
	_users = alive
	var nodes = _pass_nodes
	var managed = _pass_managed
	_pass_nodes = 0
	_pass_managed = 0
	_lod_wait = 0.15
	if _dist_new.empty() and not _users.empty():
		# Nothing could be measured. The camera or the materials may not be ready yet, so wait a while first.
		_empty_passes += 1
		if _empty_passes < 10:
			return
		if nodes == 0:
			_lod_note("%d meshes are in the scene but none of them has a current Camera in its viewport, so distance LOD cannot measure anything." % _users.size())
		else:
			_lod_note("%d meshes were measured but none of them uses a Texture Quality texture. Textures baked inside imported models (.glb / .fbx) or assigned some other way are not managed; assign the .png files in the material instead." % nodes)
	else:
		_empty_passes = 0
	for key in _entries:
		var e = _entries[key]
		var want = -2                                  # no mesh uses it: global quality level
		if _dist_new.has(key):
			want = _tier_for_distance(e, float(_dist_new[key]))
		if want != e.lod_tier:
			e.lod_tier = want
			_dirty = true
	_dist_new = {}
	_lod_unmeasured = false
	if OS.is_debug_build():
		_lod_report(nodes, managed)


# Debug builds print one line whenever the picture changes, e.g.
#   TextureQuality LOD: 212 meshes measured, 180 use baked textures; tier 0: 12, tier 3: 40, ...
func _lod_report(nodes: int, managed: int) -> void:
	var hist = {}
	for e in _entries.values():
		hist[e.lod_tier] = int(hist.get(e.lod_tier, 0)) + 1
	var keys = hist.keys()
	keys.sort()
	var parts = []
	for k in keys:
		var label = ("tier %d" % k) if k >= 0 else ("not measured yet" if k == -1 else "no mesh uses it")
		parts.append("%s: %d" % [label, hist[k]])
	_lod_note("%d meshes measured, %d use baked textures; %s; near %.1f, far %.1f; quality ceiling level %d (0 = best)" % [nodes, managed, PoolStringArray(parts).join(", "), near_distance, far_distance, _quality])


func _lod_note(text: String) -> void:
	if OS.is_debug_build() and text != _last_note:
		_last_note = text
		print("TextureQuality LOD: " + text)


# 0 = best ... last = smallest. Needs to move 0.15 of a tier past the halfway point before it changes,
# so a camera hovering at a boundary does not make the texture flip back and forth.
func _tier_for_distance(e, d: float) -> int:
	var last = e.tiers.size() - 1
	if last <= 0:
		return 0
	var span = max(far_distance - near_distance, 0.01)
	var f = clamp((d - near_distance) / span, 0.0, 1.0) * last
	var cur = e.lod_tier
	if cur >= 0 and abs(f - cur) < 0.65:
		return int(min(cur, last))
	return int(round(f))


func _measure(node, cpos: Vector3) -> void:
	var tex = _textures_of(node)
	if tex.empty():
		return
	_pass_managed += 1
	# distance to the closest point of the node's bounding box (a big floor is "near" when you stand on it)
	var box = node.get_transformed_aabb()
	var p = Vector3(clamp(cpos.x, box.position.x, box.end.x), clamp(cpos.y, box.position.y, box.end.y), clamp(cpos.z, box.position.z, box.end.z))
	var d = cpos.distance_to(p)
	for t in tex:
		var key = t.source_path
		if not _dist_new.has(key) or d < _dist_new[key]:
			_dist_new[key] = d


func _textures_of(node) -> Array:
	var out = []
	if node is Sprite3D:
		_add_tex(node.texture, out)
		return out
	if node.material_override != null:
		_add_material(node.material_override, out, 0)
	elif node.mesh != null:
		for s in range(node.mesh.get_surface_count()):
			var m = node.get_surface_material(s)
			if m == null:
				m = node.mesh.surface_get_material(s)
			if m != null:
				_add_material(m, out, 0)
	return out


func _add_tex(t, out: Array) -> void:
	if t != null and t.get_script() == StreamedTexScript and t.source_path != "":
		out.append(t)


func _add_material(m, out: Array, depth: int) -> void:
	if depth > 4:
		return
	if m is SpatialMaterial:
		for i in range(SpatialMaterial.TEXTURE_MAX):
			_add_tex(m.get_texture(i), out)
	elif m is ShaderMaterial:
		for p in m.get_property_list():
			if str(p["name"]).begins_with("shader_param/"):
				_add_tex(m.get(p["name"]), out)
	if m.next_pass != null:
		_add_material(m.next_pass, out, depth + 1)


func _worker(_userdata) -> void:
	while true:
		_sem.wait()
		if _exit:
			break
		_mutex.lock()
		var job = null
		if not _jobs.empty():
			job = _jobs.pop_front()
		_mutex.unlock()
		if job == null:
			continue
		var img = ResourceLoader.load(job["path"])
		_mutex.lock()
		_done.append({"key": job["key"], "tier": job["tier"], "image": img})
		_mutex.unlock()


func _apply_done() -> void:
	var applied = 0
	while applied < max_swaps_per_frame:
		_mutex.lock()
		var item = null
		if not _done.empty():
			item = _done.pop_front()
		_mutex.unlock()
		if item == null:
			break
		var e = _entries.get(item["key"])
		if e == null:
			continue
		e.loading = -1
		_need_schedule = true
		# Result is better than what's allowed now (budget shrank meanwhile).
		if item["tier"] < e.target:
			continue
		var img = item["image"]
		if not (img is Image):
			e.current = e.target   # give up on a broken file instead of looping
			continue
		for w in e.textures:
			var tex = w.get_ref()
			if tex != null:
				_upload(e, tex, img)
		e.current = item["tier"]
		emit_signal("tier_changed", e.key, e.current)
		applied += 1
