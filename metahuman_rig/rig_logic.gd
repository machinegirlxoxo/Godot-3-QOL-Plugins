tool
extends Reference
# Port of the MetaHuman RigLogic evaluation (GUI -> raw -> PSD -> joints / blendshapes).
# Formulas follow the open-source RigLogic implementation:
#   * GUI->raw : conditional table, interval skipping, outputs clamped to 0..1
#   * PSD      : weight * product(clamp(inputs, 0, 1)), capped at 1
#   * joints   : output[row] = sum(matrix[row][col] * input[col]), input = [raw | psd]
#   * blend    : channel weight = input value

signal outputs_changed(joints, channels)

# NOTE: Pool*Array.resize() does not zero new elements in Godot 3, so always build zeroed arrays explicitly.
static func _zeros(n: int) -> PoolRealArray:
	var a := PoolRealArray()
	a.resize(n)
	for i in range(n):
		a[i] = 0.0
	return a


var loaded := false
var raw_count := 0
var psd_count := 0
var input_count := 0
var rotation_radians := false

var raw_names := PoolStringArray()
var gui_names := PoolStringArray()
var gui_ranges := []

var _row_in := PoolIntArray()
var _row_out := PoolIntArray()
var _row_from := PoolRealArray()
var _row_to := PoolRealArray()
var _row_slope := PoolRealArray()
var _row_cut := PoolRealArray()
var _row_skip := PoolIntArray()
var _rows_by_input := {}

var gui_values := PoolRealArray()
var raw_override := PoolRealArray()
var inputs := PoolRealArray()
var _raw_acc := PoolRealArray()
var _contrib := {}

var _psd_weight := PoolRealArray()
var _psd_cols := []
var _psd_deps := {}

var joint_names := PoolStringArray()
var joint_parents := PoolIntArray()
var neutral_t := PoolRealArray()
var neutral_r := PoolRealArray()
var joint_driven := PoolByteArray()

var _col_start := PoolIntArray()
var _col_out := PoolIntArray()
var _col_val := PoolRealArray()
var out_attr := PoolRealArray()

var bs_names := PoolStringArray()
var bs_inputs := PoolIntArray()
var bs_values := PoolRealArray()
var _bs_by_input := {}

var layout := {}
var art := {}
var error := ""


func load_files(json_path: String) -> bool:
	loaded = false
	error = ""
	var f := File.new()
	if f.open(json_path, File.READ) != OK:
		error = "Cannot open " + json_path
		return false
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		error = "Invalid rig JSON"
		return false
	var d: Dictionary = parsed.result

	var bin_path := json_path.get_basename().get_basename() + ".rig.bin"
	if not f.file_exists(bin_path):
		error = "Missing " + bin_path
		return false
	if f.open(bin_path, File.READ) != OK:
		error = "Cannot open " + bin_path
		return false
	var counts = f.get_var()
	var outs = f.get_var()
	var vals = f.get_var()
	f.close()
	if typeof(counts) != TYPE_INT_ARRAY or typeof(outs) != TYPE_INT_ARRAY or typeof(vals) != TYPE_REAL_ARRAY:
		error = "Bad .rig.bin format"
		return false
	return setup(d, counts, outs, vals)


func setup(d: Dictionary, counts: PoolIntArray, outs: PoolIntArray, vals: PoolRealArray) -> bool:
	raw_count = int(d["raw_count"])
	psd_count = int(d["psd_count"])
	input_count = raw_count + psd_count
	rotation_radians = bool(d.get("rotation_radians", false))
	raw_names = PoolStringArray(d["raw_names"])
	gui_names = PoolStringArray(d["gui_names"])
	gui_ranges = d["gui_ranges"]
	layout = d.get("layout", {})
	art = d.get("art", {})

	var g: Dictionary = d["gui_rows"]
	_row_in = PoolIntArray(g["in"])
	_row_out = PoolIntArray(g["out"])
	_row_from = PoolRealArray(g["from"])
	_row_to = PoolRealArray(g["to"])
	_row_slope = PoolRealArray(g["slope"])
	_row_cut = PoolRealArray(g["cut"])
	var n := _row_in.size()
	_row_skip = PoolIntArray()
	_row_skip.resize(n)
	var i := 0
	while i < n:
		var j := i + 1
		while j < n and _row_in[j] == _row_in[i] and _row_out[j] == _row_out[i]:
			j += 1
		var run := j - i
		for k in range(run):
			_row_skip[i + k] = run - 1 - k
		i = j
	_rows_by_input.clear()
	for r in range(n):
		if not _rows_by_input.has(_row_in[r]):
			_rows_by_input[_row_in[r]] = []
		_rows_by_input[_row_in[r]].append(r)

	# PSD
	var p: Dictionary = d["psd"]
	_psd_weight = PoolRealArray()
	_psd_weight.resize(psd_count)
	_psd_cols = []
	for k in range(psd_count):
		_psd_weight[k] = 1.0
		_psd_cols.append([])
	var seen := {}
	var prows: Array = p["rows"]
	var pcols: Array = p["cols"]
	var pvals: Array = p["values"]
	for k in range(prows.size()):
		var pi: int = int(prows[k]) - raw_count
		if pi < 0 or pi >= psd_count:
			continue
		var col: int = int(pcols[k])
		_psd_weight[pi] *= float(pvals[k])
		_psd_cols[pi].append(col)
		seen[pi] = true
	_psd_deps.clear()
	for pi in range(psd_count):
		for col in _psd_cols[pi]:
			if not _psd_deps.has(col):
				_psd_deps[col] = []
			_psd_deps[col].append(pi)

	# joints
	joint_names = PoolStringArray(d["joint_names"])
	joint_parents = PoolIntArray(d["joint_parents"])
	neutral_t = PoolRealArray(d["neutral_t"])
	neutral_r = PoolRealArray(d["neutral_r"])
	_col_out = outs
	_col_val = vals
	_col_start = PoolIntArray()
	_col_start.resize(counts.size() + 1)
	var acc := 0
	for k in range(counts.size()):
		_col_start[k] = acc
		acc += counts[k]
	_col_start[counts.size()] = acc
	out_attr = _zeros(joint_names.size() * 9)
	joint_driven = PoolByteArray()
	joint_driven.resize(joint_names.size())
	for k in range(joint_driven.size()):
		joint_driven[k] = 0
	for k in range(outs.size()):
		var jj: int = outs[k] / 9
		if jj < joint_driven.size():
			joint_driven[jj] = 1

	# blendshapes
	var b: Dictionary = d["blendshapes"]
	bs_names = PoolStringArray(b["names"])
	bs_inputs = PoolIntArray(b["inputs"])
	bs_values = _zeros(bs_names.size())
	_bs_by_input.clear()
	for k in range(bs_inputs.size()):
		if not _bs_by_input.has(bs_inputs[k]):
			_bs_by_input[bs_inputs[k]] = []
		_bs_by_input[bs_inputs[k]].append(k)

	reset_state()
	loaded = true
	return true


func reset_state() -> void:
	gui_values = _zeros(gui_names.size())
	raw_override = _zeros(raw_count)
	inputs = _zeros(input_count)
	_raw_acc = _zeros(raw_count)
	_contrib.clear()
	for k in range(out_attr.size()):
		out_attr[k] = 0.0
	for k in range(bs_values.size()):
		bs_values[k] = 0.0


func reset_all() -> void:
	reset_state()
	var js := []
	for j in range(joint_names.size()):
		if joint_driven[j] == 1:
			js.append(j)
	var cs := range(bs_names.size())
	emit_signal("outputs_changed", js, cs)


func gui_index(name: String) -> int:
	return gui_names.find(name)


func set_gui_value(gi: int, v: float) -> void:
	var rng: Array = gui_ranges[gi]
	v = clamp(v, rng[0], rng[1])
	if gui_values[gi] == v:
		return
	gui_values[gi] = v
	var touched := {}
	var old: Dictionary = _contrib.get(gi, {})
	for o in old:
		_raw_acc[o] -= old[o]
		touched[o] = true
	var fresh := {}
	if _rows_by_input.has(gi):
		var rows: Array = _rows_by_input[gi]
		var k := 0
		while k < rows.size():
			var r: int = rows[k]
			if _row_from[r] <= v and v <= _row_to[r]:
				var o: int = _row_out[r]
				fresh[o] = fresh.get(o, 0.0) + _row_slope[r] * v + _row_cut[r]
				k += 1 + _row_skip[r]
			else:
				k += 1
	_contrib[gi] = fresh
	for o in fresh:
		_raw_acc[o] += fresh[o]
		touched[o] = true
	_propagate(touched.keys())


func set_raw_override(ri: int, v: float) -> void:
	v = clamp(v, 0.0, 1.0)
	if raw_override[ri] == v:
		return
	raw_override[ri] = v
	_propagate([ri])


func _propagate(raw_list: Array) -> void:
	var changed := {}
	var dirty := {}
	for o in raw_list:
		var nv: float = clamp(clamp(_raw_acc[o], 0.0, 1.0) + raw_override[o], 0.0, 1.0)
		if abs(nv - inputs[o]) > 1e-7:
			changed[o] = nv
			if _psd_deps.has(o):
				for pi in _psd_deps[o]:
					dirty[pi] = true
	if not dirty.empty():
		for pi in range(psd_count):
			if not dirty.has(pi):
				continue
			var val: float = _psd_weight[pi]
			for col in _psd_cols[pi]:
				var src: float = changed.get(col, inputs[col])
				val *= clamp(src, 0.0, 1.0)
			val = min(1.0, val)
			var idx := raw_count + pi
			if abs(val - inputs[idx]) > 1e-7:
				changed[idx] = val
				if _psd_deps.has(idx):
					for q in _psd_deps[idx]:
						dirty[q] = true
	var joints := {}
	var chans := {}
	for idx in changed:
		var delta: float = changed[idx] - inputs[idx]
		inputs[idx] = changed[idx]
		var s: int = _col_start[idx]
		var e: int = _col_start[idx + 1]
		for k in range(s, e):
			var out: int = _col_out[k]
			out_attr[out] += delta * _col_val[k]
			joints[out / 9] = true
		if _bs_by_input.has(idx):
			for c in _bs_by_input[idx]:
				bs_values[c] = changed[idx]
				chans[c] = true
	if not joints.empty() or not chans.empty():
		emit_signal("outputs_changed", joints.keys(), chans.keys())
