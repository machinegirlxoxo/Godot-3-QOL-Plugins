tool
extends Reference
# Turns the JSON from api.polyhaven.com/files/<id> into a list of files to download.
# Nothing here touches the network or the disk.

const SKIP_KEYS = ["blend", "gltf", "mtlx", "usd", "fbx"]
const STANDARD_EXCLUDE = ["nor_dx", "arm"]       # DirectX normals and the packed ARM map
const TEXTURE_FALLBACK = ["jpg", "png", "exr"]

var _id_regex: RegEx


func _init() -> void:
	_id_regex = RegEx.new()
	_id_regex.compile("^[A-Za-z0-9_\\-]+$")


func _res_less(a: String, b: String) -> bool:
	return float(a.trim_suffix("k")) < float(b.trim_suffix("k"))


func _map_keys(files: Dictionary, all_maps: bool) -> Array:
	var keys = []
	for k in files.keys():
		if SKIP_KEYS.has(k):
			continue
		if not all_maps and STANDARD_EXCLUDE.has(k):
			continue
		if files[k] is Dictionary:
			keys.append(k)
	return keys


# asset type: 0 = HDRI, 1 = texture (material), 2 = model
func resolutions(type: int, files: Dictionary, all_maps: bool) -> Array:
	var out = []
	if type == 0:
		if files.get("hdri") is Dictionary:
			out = files["hdri"].keys()
	elif type == 1:
		for k in _map_keys(files, all_maps):
			for r in files[k].keys():
				if not out.has(r):
					out.append(r)
	elif type == 2:
		if files.get("gltf") is Dictionary:
			out = files["gltf"].keys()
	out.sort_custom(self, "_res_less")
	return out


func formats(type: int, files: Dictionary, res: String, all_maps: bool) -> Array:
	var out = []
	if type == 0:
		var d = files.get("hdri")
		if d is Dictionary and d.get(res) is Dictionary:
			out = d[res].keys()
	elif type == 1:
		for k in _map_keys(files, all_maps):
			if files[k].get(res) is Dictionary:
				for f in files[k][res].keys():
					if not out.has(f):
						out.append(f)
	else:
		out = ["gltf"]
	return out


func _safe_url(url) -> bool:
	if not (url is String) or not url.begins_with("https://"):
		return false
	var host: String = url.substr(8).split("/")[0]
	return host.ends_with("polyhaven.org") or host.ends_with("polyhaven.com")


func _safe_rel(rel: String) -> bool:
	return rel != "" and not (".." in rel) and not rel.begins_with("/") and not (":" in rel) and not ("\\" in rel)


func _file_name(url: String) -> String:
	return url.split("?")[0].get_file()


func _add_job(result: Dictionary, file, path: String) -> bool:
	if not (file is Dictionary) or not _safe_url(file.get("url")):
		result["error"] = "Unexpected download URL for " + path.get_file()
		return false
	result["jobs"].append({
		"url": file["url"],
		"path": path,
		"size": int(file.get("size", 0)),
		"md5": str(file.get("md5", "")),
	})
	return true


# Returns {ok, error, jobs: [{url, path, size, md5}], folder, maps: {mapName: path}}
func plan(type: int, id: String, files: Dictionary, res: String, fmt: String, all_maps: bool, base_dir: String) -> Dictionary:
	var result = {"ok": false, "error": "", "jobs": [], "folder": "", "maps": {}}
	if _id_regex.search(id) == null:
		result["error"] = "Unexpected asset id."
		return result
	base_dir = base_dir.strip_edges().trim_suffix("/")
	if not base_dir.begins_with("res://"):
		result["error"] = "The save folder must start with res://"
		return result

	if type == 0:
		var d = files.get("hdri")
		if not (d is Dictionary) or not (d.get(res) is Dictionary) or d[res].empty():
			result["error"] = "No HDRI file at this resolution."
			return result
		var chosen = fmt
		if not d[res].has(chosen):
			chosen = d[res].keys()[0]
		result["folder"] = base_dir + "/HDRI"
		if not _add_job(result, d[res][chosen], "%s/%s_%s.%s" % [result["folder"], id, res, chosen]):
			return result
	elif type == 1:
		result["folder"] = base_dir + "/Materials/" + id
		for k in _map_keys(files, all_maps):
			var by_res = files[k].get(res)
			if not (by_res is Dictionary) or by_res.empty():
				continue
			var chosen = fmt
			if not by_res.has(chosen):
				chosen = ""
				for f in TEXTURE_FALLBACK:
					if by_res.has(f):
						chosen = f
						break
				if chosen == "":
					chosen = by_res.keys()[0]
			var file = by_res[chosen]
			if not (file is Dictionary):
				continue
			var path = result["folder"] + "/" + _file_name(str(file.get("url", "")))
			if not _add_job(result, file, path):
				return result
			result["maps"][k] = path
	elif type == 2:
		var g = files.get("gltf")
		if not (g is Dictionary) or not (g.get(res) is Dictionary) or not (g[res].get("gltf") is Dictionary):
			result["error"] = "No glTF file at this resolution."
			return result
		var file = g[res]["gltf"]
		result["folder"] = base_dir + "/Models/" + id
		if not _add_job(result, file, result["folder"] + "/" + _file_name(str(file.get("url", "")))):
			return result
		var include = file.get("include", {})
		for rel in include.keys():
			if not _safe_rel(rel):
				result["error"] = "Unexpected file path in model data."
				result["jobs"] = []
				return result
			if not _add_job(result, include[rel], result["folder"] + "/" + rel):
				return result

	result["ok"] = not result["jobs"].empty()
	if not result["ok"] and result["error"] == "":
		result["error"] = "Nothing to download for these settings."
	return result
