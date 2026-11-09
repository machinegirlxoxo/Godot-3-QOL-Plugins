tool
extends Node
# Turns the JSON sent by the Fab launcher (Custom socket export) into files inside the project.
#
# The JSON layout follows the one Quixel Bridge used for its socket export (an array of assets,
# each with path / meshList / lodList / components / packedTextures). Key names are matched
# case-insensitively and, if the JSON has no texture list, the asset folder is scanned instead,
# so small differences in the launcher's output do not break the import.

signal log_line(text)

const IMAGE_EXT = ["jpg", "jpeg", "png", "tga", "webp", "bmp", "exr", "hdr"]
const MESH_EXT = ["glb", "gltf", "fbx", "obj"]      # in order of preference
const SIDECAR_EXT = ["bin", "mtl"]

const FOLIAGE_SHADER = """shader_type spatial;
render_mode cull_disabled, depth_draw_alpha_prepass;
uniform sampler2D albedo_tex : hint_albedo;
uniform sampler2D opacity_tex : hint_white;
uniform sampler2D normal_tex : hint_normal;
uniform sampler2D rough_tex : hint_white;
uniform sampler2D ao_tex : hint_white;
uniform float alpha_cut = 0.5;
void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb;
	ALPHA = texture(opacity_tex, UV).r;
	ALPHA_SCISSOR = alpha_cut;
	NORMALMAP = texture(normal_tex, UV).xyz;
	ROUGHNESS = texture(rough_tex, UV).r;
	AO = texture(ao_tex, UV).r;
	AO_LIGHT_AFFECT = 1.0;
}
"""

var editor: EditorInterface


# ------------------------------------------------------------------- parsing

static func _pick(d: Dictionary, names: Array, def = null):
	for k in d.keys():
		if names.has(str(k).to_lower()):
			return d[k]
	return def


static func _fix(p) -> String:
	return str(p).replace("\\", "/")


static func _abs(p: String, dir: String) -> String:
	p = _fix(p)
	if p == "" or p.is_abs_path():
		return p
	return dir.plus_file(p)


static func role_for(t: String) -> String:
	match t.to_lower():
		"albedo", "diffuse", "basecolor", "base_color", "color", "diff":
			return "albedo"
		"normal", "nor", "nor_gl", "normal_gl":
			return "normal"
		"roughness", "rough":
			return "roughness"
		"metalness", "metallic", "metal":
			return "metallic"
		"ao", "occlusion", "ambientocclusion":
			return "ao"
		"displacement", "height", "disp":
			return "displacement"
		"opacity", "alpha":
			return "opacity"
		"translucency", "transmission":
			return "translucency"
		"emission", "emissive":
			return "emission"
	return ""


static func _lod_number(v) -> int:
	var digits = ""
	for ch in str(v):
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		return 0
	return int(digits)


static func _res_score(name: String) -> int:
	# "2k" / "4K" / "8k" tokens in a file name; bigger is better.
	var best = 0
	for tok in name.to_lower().replace("-", "_").split("_"):
		if tok.length() >= 2 and tok.ends_with("k") and tok.trim_suffix("k").is_valid_integer():
			best = max(best, int(tok.trim_suffix("k")))
	return best


# raw JSON (array or object) -> Array of normalized asset dictionaries
func normalize(raw) -> Array:
	var list = []
	if raw is Array:
		list = raw
	elif raw is Dictionary:
		var inner = _pick(raw, ["assets"])
		list = inner if inner is Array else [raw]
	var out = []
	for a in list:
		if a is Dictionary:
			out.append(_normalize_one(a))
	return out


func _normalize_one(a: Dictionary) -> Dictionary:
	var dir = _fix(_pick(a, ["path", "folder", "directory", "assetpath"], ""))
	var asset = {
		"id": str(_pick(a, ["id", "assetid", "asset_id"], "")),
		"name": str(_pick(a, ["name", "assetname", "title"], "")),
		"type": str(_pick(a, ["type", "assettype"], "")).to_lower(),
		"dir": dir,
		"meshes": [],     # {path, format, lod}
		"lods": [],       # {path, format, lod}
		"textures": {},   # role -> path
		"packed": [],     # {path, channels: {r,g,b,a -> role}}
	}

	for m in _array(_pick(a, ["meshlist", "meshes"])):
		var e = _mesh_entry(m, dir)
		if not e.empty():
			asset["meshes"].append(e)
	for m in _array(_pick(a, ["lodlist"])):
		var e2 = _mesh_entry(m, dir)
		if not e2.empty():
			asset["lods"].append(e2)

	for c in _array(_pick(a, ["components", "textures", "maps"])):
		if not (c is Dictionary):
			continue
		var p = _abs(str(_pick(c, ["path", "file", "filepath"], "")), dir)
		var role = role_for(str(_pick(c, ["type", "name", "channel"], "")))
		if p != "" and role != "" and not asset["textures"].has(role):
			asset["textures"][role] = p

	for t in _array(_pick(a, ["packedtextures"])):
		if not (t is Dictionary):
			continue
		var tp = _abs(str(_pick(t, ["path", "file"], "")), dir)
		var cd = _pick(t, ["channelsdata", "channels"], {})
		var ch = {}
		if cd is Dictionary:
			for key in ["red", "green", "blue", "alpha"]:
				var entry = _pick(cd, [key])
				if entry is Dictionary:
					var r = role_for(str(_pick(entry, ["type", "name"], "")))
					if r != "":
						ch[key[0]] = r
		if tp != "" and not ch.empty():
			asset["packed"].append({"path": tp, "channels": ch})

	# Fallback: nothing usable in the JSON -> look at the folder.
	if dir != "" and asset["textures"].empty():
		_scan_folder(asset, dir, 0)

	if asset["type"] == "":
		asset["type"] = "3d" if (not asset["meshes"].empty() or not asset["lods"].empty()) else "surface"
	if asset["name"] == "":
		asset["name"] = dir.get_file() if dir != "" else asset["id"]
	if asset["name"] == "":
		asset["name"] = "FabAsset"
	return asset


static func _array(v) -> Array:
	return v if v is Array else []


func _mesh_entry(m, dir: String) -> Dictionary:
	if not (m is Dictionary):
		return {}
	var p = _abs(str(_pick(m, ["path", "file", "filepath"], "")), dir)
	if p == "":
		return {}
	var ext = p.get_extension().to_lower()
	if not MESH_EXT.has(ext):
		return {}
	var lod_v = _pick(m, ["lod"])
	if lod_v == null:
		lod_v = p.get_file()
		var low = str(lod_v).to_lower()
		var pos = low.rfind("lod")
		lod_v = low.substr(pos) if pos != -1 else "0"
	return {"path": p, "format": ext, "lod": _lod_number(lod_v)}


# Folder scan used when the JSON does not list files (or for "Import from folder").
func _scan_folder(asset: Dictionary, dir: String, depth: int) -> void:
	var d = Directory.new()
	if d.open(dir) != OK:
		return
	var best = {}   # role -> score
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		var full = dir.plus_file(f)
		if d.current_is_dir():
			if depth < 2:
				_scan_folder(asset, full, depth + 1)
		else:
			var ext = f.get_extension().to_lower()
			if IMAGE_EXT.has(ext):
				var role = ""
				for tok in f.get_basename().to_lower().replace("-", "_").split("_"):
					role = role_for(tok)
					if role != "":
						break
				if role != "":
					var score = _res_score(f)
					if not asset["textures"].has(role) or score > best.get(role, 0):
						asset["textures"][role] = full
						best[role] = score
			elif MESH_EXT.has(ext):
				var already = false
				for m in asset["meshes"]:
					if m["path"] == full:
						already = true
				if not already:
					var low = f.to_lower()
					var pos = low.rfind("lod")
					asset["meshes"].append({"path": full, "format": ext, "lod": _lod_number(low.substr(pos)) if pos != -1 else 0})
		f = d.get_next()
	d.list_dir_end()


# Builds an asset description from a plain folder (for "Import from folder...").
func asset_from_folder(dir: String) -> Dictionary:
	dir = _fix(dir)
	var asset = {"id": "", "name": dir.get_file(), "type": "", "dir": dir, "meshes": [], "lods": [], "textures": {}, "packed": []}
	_scan_folder(asset, dir, 0)
	asset["type"] = "3d" if not asset["meshes"].empty() else "surface"
	return asset


# ----------------------------------------------------------------- planning

static func safe_name(s: String) -> String:
	var out = ""
	for ch in s.strip_edges():
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		elif ch == " " or ch == ".":
			out += "_"
	return out.substr(0, 60) if out != "" else "Asset"


static func type_folder(type: String) -> String:
	match type:
		"surface", "surfaces":
			return "Surfaces"
		"3dplant", "plant":
			return "Plants"
		"atlas", "decal":
			return "Atlases"
	return "Assets"


static func _safe_dest(p: String) -> bool:
	return p.begins_with("res://") and not (".." in p)


func pick_meshes(asset: Dictionary, lod: int) -> Array:
	var src = []
	if not asset["lods"].empty():
		var wanted = -1
		var max_lod = 0
		for m in asset["lods"]:
			max_lod = max(max_lod, m["lod"])
		# smallest available LOD that is >= the wanted one, else the highest available
		var avail = []
		for m in asset["lods"]:
			if not avail.has(m["lod"]):
				avail.append(m["lod"])
		avail.sort()
		wanted = max_lod
		for l in avail:
			if l >= lod:
				wanted = l
				break
		for m in asset["lods"]:
			if m["lod"] == wanted:
				src.append(m)
	else:
		src = asset["meshes"]
	var by_base = {}
	for m in src:
		var base = m["path"].get_file().get_basename().to_lower()
		if not by_base.has(base) or MESH_EXT.find(m["format"]) < MESH_EXT.find(by_base[base]["format"]):
			by_base[base] = m
	return by_base.values()


# ------------------------------------------------------------------- import
# opts: {base_dir, lod, make_material, make_scene, parallax}
# Returns {ok, error, name, folder, material, scene, files}
func import_asset(asset: Dictionary, opts: Dictionary):
	yield(get_tree(), "idle_frame")
	var res = {"ok": false, "error": "", "name": asset["name"], "folder": "", "material": "", "scene": "", "files": 0}

	var base = str(opts.get("base_dir", "res://Fab")).strip_edges().trim_suffix("/")
	if not _safe_dest(base):
		res["error"] = "The save folder must start with res:// and must not contain '..'."
		return res

	var name = safe_name(asset["name"])
	var folder = "%s/%s/%s" % [base, type_folder(asset["type"]), name]
	res["folder"] = folder
	var tex_dir = folder + "/Textures"

	var dir = Directory.new()
	dir.make_dir_recursive(tex_dir)

	# Collect everything that must be copied: [src, dst]
	var jobs = []
	var tex_dst = {}        # role -> res path
	for role in asset["textures"].keys():
		var src = asset["textures"][role]
		var dst = tex_dir + "/" + safe_name(src.get_file().get_basename()) + "." + src.get_extension().to_lower()
		if IMAGE_EXT.has(src.get_extension().to_lower()):
			jobs.append([src, dst])
			tex_dst[role] = dst
	var packed_dst = []     # {path, channels}
	for pk in asset["packed"]:
		var psrc: String = pk["path"]
		if IMAGE_EXT.has(psrc.get_extension().to_lower()):
			var pdst = tex_dir + "/" + safe_name(psrc.get_file().get_basename()) + "." + psrc.get_extension().to_lower()
			jobs.append([psrc, pdst])
			packed_dst.append({"path": pdst, "channels": pk["channels"]})

	var meshes_dst = []
	for m in pick_meshes(asset, int(opts.get("lod", 0))):
		var msrc: String = m["path"]
		var mdst = folder + "/" + safe_name(msrc.get_file().get_basename()) + "." + m["format"]
		jobs.append([msrc, mdst])
		meshes_dst.append(mdst)
		for side in _sidecars(msrc):
			jobs.append([side, folder + "/" + side.get_file()])

	if jobs.empty():
		res["error"] = "The export contained no textures or meshes Godot can use."
		return res

	# Copy (or check, when the files are already inside the project)
	var file = File.new()
	for j in jobs:
		var src: String = j[0]
		var dst: String = j[1]
		if not _safe_dest(dst):
			res["error"] = "Refused an unsafe destination path."
			return res
		if not file.file_exists(src):
			emit_signal("log_line", "Missing file, skipped: " + src)
			continue
		if _same_size(src, dst):
			res["files"] += 1
			continue
		emit_signal("log_line", "Copying " + src.get_file())
		if not _copy_file(src, dst):
			res["error"] = "Could not copy " + src.get_file()
			return res
		res["files"] += 1
		yield(get_tree(), "idle_frame")

	editor.get_resource_filesystem().scan()

	var wait_list = []
	for r in tex_dst.keys():
		wait_list.append(tex_dst[r])
	for pk2 in packed_dst:
		wait_list.append(pk2["path"])
	for md in meshes_dst:
		wait_list.append(md)
	var imported = yield(_wait_for_imports(wait_list, 120.0), "completed")
	if not imported:
		res["ok"] = true
		res["error"] = "Files were copied, but the editor import took too long to build the material/scene. Do that by hand."
		return res

	var material = null
	if bool(opts.get("make_material", true)) and (not tex_dst.empty() or not packed_dst.empty()):
		material = build_material(tex_dst, packed_dst, bool(opts.get("parallax", false)))
		if material != null:
			var mpath = "%s/%s.tres" % [folder, name]
			if ResourceSaver.save(mpath, material) == OK:
				res["material"] = mpath
				material = load(mpath)
			else:
				res["error"] = "Could not save the material."

	if bool(opts.get("make_scene", true)) and not meshes_dst.empty():
		var spath = "%s/%s.scn" % [folder, name]
		if _build_scene(meshes_dst, material, spath, name):
			res["scene"] = spath
		else:
			res["error"] = "Meshes were copied, but the scene could not be built."

	res["ok"] = true
	editor.get_resource_filesystem().scan()
	return res


func _sidecars(mesh_path: String) -> Array:
	var out = []
	var d = Directory.new()
	var dir = mesh_path.get_base_dir()
	var ext = mesh_path.get_extension().to_lower()
	var base = mesh_path.get_file().get_basename()
	if d.open(dir) != OK:
		return out
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var e = f.get_extension().to_lower()
			if SIDECAR_EXT.has(e):
				if f.get_basename() == base or (ext == "gltf" and e == "bin"):
					out.append(dir.plus_file(f))
		f = d.get_next()
	d.list_dir_end()
	return out


func _same_size(src: String, dst: String) -> bool:
	var a = File.new()
	var b = File.new()
	if not b.file_exists(dst) or a.open(src, File.READ) != OK:
		return false
	var sa = a.get_len()
	a.close()
	if b.open(dst, File.READ) != OK:
		return false
	var sb = b.get_len()
	b.close()
	return sa == sb


func _copy_file(src: String, dst: String) -> bool:
	var f = File.new()
	if f.open(src, File.READ) != OK:
		return false
	var o = File.new()
	if o.open(dst, File.WRITE) != OK:
		f.close()
		return false
	var left = f.get_len()
	while left > 0:
		var n = int(min(left, 1048576))
		o.store_buffer(f.get_buffer(n))
		left -= n
	f.close()
	o.close()
	return true


func _wait_for_imports(paths: Array, timeout: float):
	yield(get_tree(), "idle_frame")
	var file = File.new()
	var waited = 0.0
	while waited < timeout:
		var ready = true
		for p in paths:
			if not file.file_exists(p + ".import"):
				ready = false
				break
		if ready:
			yield(get_tree().create_timer(1.0), "timeout")
			return true
		yield(get_tree().create_timer(0.5), "timeout")
		waited += 0.5
	return false


# ---------------------------------------------------------------- materials

static func _channel_const(c: String) -> int:
	match c:
		"g":
			return SpatialMaterial.TEXTURE_CHANNEL_GREEN
		"b":
			return SpatialMaterial.TEXTURE_CHANNEL_BLUE
		"a":
			return SpatialMaterial.TEXTURE_CHANNEL_ALPHA
	return SpatialMaterial.TEXTURE_CHANNEL_RED


# tex_paths: role -> res path;  packed: [{path, channels}]
func build_material(tex_paths: Dictionary, packed: Array, parallax: bool) -> Material:
	var tex = {}                    # role -> {tex, ch}
	for role in tex_paths.keys():
		var t = load(tex_paths[role])
		if t is Texture:
			tex[role] = {"tex": t, "ch": "r"}
	for pk in packed:
		var pt = load(pk["path"])
		if not (pt is Texture):
			continue
		for ch in pk["channels"].keys():
			var role = pk["channels"][ch]
			if not tex.has(role):
				tex[role] = {"tex": pt, "ch": ch}

	if not tex.has("albedo") and not tex.has("normal") and not tex.has("roughness"):
		return null

	if tex.has("opacity") and tex.has("albedo"):
		var sm = ShaderMaterial.new()
		var sh = Shader.new()
		sh.code = FOLIAGE_SHADER
		sm.shader = sh
		sm.set_shader_param("albedo_tex", tex["albedo"]["tex"])
		sm.set_shader_param("opacity_tex", tex["opacity"]["tex"])
		if tex.has("normal"):
			sm.set_shader_param("normal_tex", tex["normal"]["tex"])
		if tex.has("roughness") and tex["roughness"]["ch"] == "r":
			sm.set_shader_param("rough_tex", tex["roughness"]["tex"])
		if tex.has("ao") and tex["ao"]["ch"] == "r":
			sm.set_shader_param("ao_tex", tex["ao"]["tex"])
		return sm

	var m = SpatialMaterial.new()
	if tex.has("albedo"):
		m.albedo_texture = tex["albedo"]["tex"]
	if tex.has("normal"):
		m.normal_enabled = true
		m.normal_texture = tex["normal"]["tex"]
	if tex.has("roughness"):
		m.roughness = 1.0
		m.roughness_texture = tex["roughness"]["tex"]
		m.roughness_texture_channel = _channel_const(tex["roughness"]["ch"])
	if tex.has("metallic"):
		m.metallic = 1.0
		m.metallic_texture = tex["metallic"]["tex"]
		m.metallic_texture_channel = _channel_const(tex["metallic"]["ch"])
	if tex.has("ao"):
		m.ao_enabled = true
		m.ao_texture = tex["ao"]["tex"]
		m.ao_texture_channel = _channel_const(tex["ao"]["ch"])
	if tex.has("emission"):
		m.emission_enabled = true
		m.emission_texture = tex["emission"]["tex"]
	if tex.has("translucency"):
		m.transmission_enabled = true
		m.transmission = Color(0.5, 0.5, 0.5)
	if parallax and tex.has("displacement") and tex["displacement"]["ch"] == "r":
		m.depth_enabled = true
		m.depth_scale = 0.05
		m.depth_texture = tex["displacement"]["tex"]
	return m


# -------------------------------------------------------------------- scene

func _build_scene(mesh_paths: Array, material, scene_path: String, root_name: String) -> bool:
	var root = Spatial.new()
	root.name = root_name
	var added = 0
	for mp in mesh_paths:
		var ps = load(mp)
		if ps is PackedScene:          # glTF / FBX import as scenes
			var inst = ps.instance()
			root.add_child(inst)
			_own_recursive(inst, root, material)
			added += 1
		elif ps is Mesh:               # OBJ imports as a bare mesh
			var mi = MeshInstance.new()
			mi.name = mp.get_file().get_basename()
			mi.mesh = ps
			if material != null:
				mi.material_override = material
			root.add_child(mi)
			mi.owner = root
			added += 1
	var ok = false
	if added > 0:
		var packed = PackedScene.new()
		if packed.pack(root) == OK:
			ok = ResourceSaver.save(scene_path, packed) == OK
	root.free()
	return ok


func _own_recursive(n: Node, root: Node, material) -> void:
	n.owner = root
	if material != null and n is MeshInstance:
		n.material_override = material
	for c in n.get_children():
		_own_recursive(c, root, material)
