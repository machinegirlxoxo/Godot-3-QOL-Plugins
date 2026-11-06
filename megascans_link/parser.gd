tool
extends Reference
# Pure logic: no network, no disk writes.
# Turns the JSON that Quixel Bridge ("Custom Socket Export") or the Fab exporter sends into a
# normalised asset, and turns an asset into a list of files to copy into the project.

const TEX_EXT = ["jpg", "jpeg", "png", "exr", "tga", "webp", "bmp", "hdr"]
const MESH_EXT = ["obj", "glb", "gltf", "dae"]
const SUBFOLDERS = {
	"surface": "Surfaces",
	"3d": "Models",
	"3dplant": "Plants",
	"atlas": "Atlases",
	"brush": "Brushes",
}

var _bad_chars: RegEx
var _bad_name_chars: RegEx
var _lod_regex: RegEx


func _init() -> void:
	_bad_chars = RegEx.new()
	_bad_chars.compile("[^A-Za-z0-9_\\-]")
	_bad_name_chars = RegEx.new()
	_bad_name_chars.compile("[^A-Za-z0-9._\\-]")
	_lod_regex = RegEx.new()
	_lod_regex.compile("lod(\\d+)")


# ------------------------------------------------------------------ small helpers

func slug(s: String) -> String:
	var out = _bad_chars.sub(s.to_lower().replace(" ", "_"), "_", true)
	while "__" in out:
		out = out.replace("__", "_")
	while out.begins_with("_"):
		out = out.substr(1)
	while out.ends_with("_"):
		out = out.substr(0, out.length() - 1)
	if out.length() > 40:
		out = out.substr(0, 40)
	if out == "":
		out = "asset"
	return out


func safe_id(s: String) -> String:
	return _bad_chars.sub(s.strip_edges(), "_", true)


func safe_file_name(n: String) -> String:
	var out = _bad_name_chars.sub(n, "_", true)
	while out.begins_with("."):
		out = out.substr(1)
	if out == "":
		out = "file"
	return out


# Maps a Bridge component type ("albedo", "nor_gl", ...) to a material role, or "".
func role_of_type(t: String) -> String:
	match t.to_lower().replace("_", "").replace(" ", ""):
		"albedo", "diffuse", "basecolor", "color", "colour":
			return "albedo"
		"normal", "normalgl", "norgl":
			return "normal"
		"roughness":
			return "roughness"
		"gloss", "glossiness":
			return "gloss"
		"metalness", "metallic", "metal":
			return "metallic"
		"ao", "occlusion", "ambientocclusion":
			return "ao"
		"opacity", "alpha":
			return "opacity"
		"displacement", "height":
			return "displacement"
		"emission", "emissive":
			return "emission"
	return ""


# Guesses the material role from a file name such as "T_abc_4K_Albedo.jpg". Used for
# folder imports and for Fab exports that list plain file paths.
func guess_role(file_name: String) -> String:
	var base = file_name.get_basename().to_lower()
	for sep in ["-", ".", " "]:
		base = base.replace(sep, "_")
	var tokens = base.split("_", false)
	for t in tokens:
		if t == "dx" or t == "directx":
			return ""    # DirectX normal maps are the wrong way round for Godot
	# The map name is normally the last token ("Metal_Plate_Roughness"), so search backwards.
	for i in range(tokens.size() - 1, -1, -1):
		var t = tokens[i]
		var r = role_of_type(t)
		if r != "":
			return r
		match t:
			"nor", "nrm", "nrml", "norm":
				return "normal"
			"rough", "rgh":
				return "roughness"
			"met":
				return "metallic"
			"disp":
				return "displacement"
			"alb", "col", "bc":
				return "albedo"
			"occ":
				return "ao"
			"opac":
				return "opacity"
	return ""


func lod_of(path: String) -> int:
	var m = _lod_regex.search(path.get_file().to_lower())
	return int(m.get_string(1)) if m != null else -1


# For a scene we only want the highest-detail LOD, plus any mesh that is not an LOD.
func scene_meshes(meshes: Array) -> Array:
	var best = 100000
	for m in meshes:
		var l = lod_of(m)
		if l >= 0 and l < best:
			best = l
	var out = []
	for m in meshes:
		var l = lod_of(m)
		if l < 0 or l == best:
			out.append(m)
	return out


# ------------------------------------------------------------------------ parsing

# Returns {ok, error, assets: [normalised asset]}.
func parse_payload(text: String) -> Dictionary:
	var res = {"ok": false, "error": "", "assets": []}
	var parsed = JSON.parse(text)
	if parsed.error != OK:
		res["error"] = "Received data that is not valid JSON."
		return res
	var data = parsed.result
	var list = []
	if data is Array:
		list = data
	elif data is Dictionary:
		if data.get("assets") is Array:
			list = data["assets"]
		else:
			list = [data]
	for raw in list:
		if raw is Dictionary:
			var a = _normalise(raw)
			if a["id"] != "":
				res["assets"].append(a)
	res["ok"] = not res["assets"].empty()
	if not res["ok"]:
		res["error"] = "The data did not contain any assets."
	return res


func _join(v) -> String:
	if v is Array:
		var parts = PoolStringArray()
		for x in v:
			parts.append(str(x))
		return parts.join(" / ")
	return str(v) if v != null else ""


func _normalise(raw: Dictionary) -> Dictionary:
	var id = safe_id(str(raw.get("id", "")))
	var name = str(raw.get("name", ""))
	if name.strip_edges() == "":
		name = id

	var components = []
	if raw.get("components") is Array:
		for c in raw["components"]:
			if c is Dictionary and str(c.get("path", "")) != "":
				components.append({
					"type": str(c.get("type", "")),
					"format": str(c.get("format", "")),
					"path": str(c["path"]),
					"name": str(c.get("name", "")),
				})
	# Fab-style exports can also list plain texture paths.
	if raw.get("additional_textures") is Array:
		for p in raw["additional_textures"]:
			if p is String and p != "":
				components.append({"type": "", "format": p.get_extension().to_lower(), "path": p, "name": p.get_file()})

	var meshes = []
	if raw.get("meshList") is Array:
		for m in raw["meshList"]:
			if m is Dictionary and str(m.get("path", "")) != "":
				var p = str(m["path"])
				meshes.append({"format": p.get_extension().to_lower(), "path": p, "name": str(m.get("name", p.get_file()))})

	var type = str(raw.get("type", "")).to_lower()
	if type == "":
		type = "3d" if not meshes.empty() else "surface"

	var preview = str(raw.get("previewImage", raw.get("preview", "")))
	if preview.begins_with("http"):
		preview = ""

	return {
		"id": id,
		"name": name,
		"type": type,
		"category": _join(raw.get("category", raw.get("categories", ""))),
		"preview": preview,
		"resolution": str(raw.get("resolution", "")),
		"components": components,
		"meshes": meshes,
	}


# Builds an asset out of a plain list of absolute file paths (folder import).
func asset_from_folder(files: Array, folder_name: String) -> Dictionary:
	var components = []
	var meshes = []
	for f in files:
		var ext = str(f).get_extension().to_lower()
		if TEX_EXT.has(ext):
			components.append({"type": "", "format": ext, "path": f, "name": str(f).get_file()})
		elif MESH_EXT.has(ext) or ext == "fbx":
			meshes.append({"format": ext, "path": f, "name": str(f).get_file()})
	return {
		"id": slug(folder_name),
		"name": folder_name,
		"type": "3d" if not meshes.empty() else "surface",
		"category": "",
		"preview": "",
		"resolution": "",
		"components": components,
		"meshes": meshes,
	}


# --------------------------------------------------------------------------- plan

# Returns {ok, error, folder, slug, jobs: [{src, dst}], maps: {role: dst}, meshes: [dst], notes: [String]}.
func build_plan(asset: Dictionary, base_dir: String) -> Dictionary:
	var plan = {"ok": false, "error": "", "folder": "", "slug": "", "jobs": [], "maps": {}, "meshes": [], "notes": []}
	base_dir = base_dir.strip_edges().trim_suffix("/")
	if not base_dir.begins_with("res://") or ".." in base_dir:
		plan["error"] = "The save folder must start with res://"
		return plan

	var name_slug = slug(str(asset["name"]))
	var tail = name_slug
	if name_slug != str(asset["id"]).to_lower():
		tail = name_slug + "_" + str(asset["id"])
	var folder = "%s/%s/%s" % [base_dir, SUBFOLDERS.get(asset["type"], "Other"), tail]
	plan["folder"] = folder
	plan["slug"] = name_slug

	var used = {}
	var skipped_tex = 0
	for c in asset["components"]:
		var src: String = c["path"]
		if not TEX_EXT.has(src.get_extension().to_lower()):
			skipped_tex += 1
			continue
		var dst = folder + "/" + safe_file_name(src.get_file())
		if used.has(dst):
			continue
		used[dst] = true
		plan["jobs"].append({"src": src, "dst": dst})
		var role = ""
		if str(c["type"]) != "":
			role = role_of_type(c["type"])
		else:
			role = guess_role(src.get_file())
		if role != "" and not plan["maps"].has(role):
			plan["maps"][role] = dst
	if skipped_tex > 0:
		plan["notes"].append("%d texture file(s) in an unsupported format were skipped." % skipped_tex)

	var skipped_mesh = 0
	for m in asset["meshes"]:
		var msrc: String = m["path"]
		if not MESH_EXT.has(msrc.get_extension().to_lower()):
			skipped_mesh += 1
			continue
		var mdst = folder + "/" + safe_file_name(msrc.get_file())
		if used.has(mdst):
			continue
		used[mdst] = true
		plan["jobs"].append({"src": msrc, "dst": mdst})
		plan["meshes"].append(mdst)
	if skipped_mesh > 0:
		plan["notes"].append("%d mesh file(s) skipped: Godot 3 cannot import FBX. In Bridge's export settings set the mesh format to OBJ." % skipped_mesh)

	plan["ok"] = not plan["jobs"].empty()
	if not plan["ok"]:
		plan["error"] = "Nothing importable in this asset."
	return plan
