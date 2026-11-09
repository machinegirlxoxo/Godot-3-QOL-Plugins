tool
extends TabContainer
# The AssetBrowser main screen: one sub-tab per marketplace.
# To add another marketplace: write a Control script with `var editor` and `func on_shown()`,
# then add one line to PROVIDERS below.

const PROVIDERS = [
	{"name": "PolyHaven", "title": "Poly Haven", "script": "res://addons/asset_browser/providers/polyhaven/browser.gd"},
	{"name": "Fab", "title": "Fab / Megascans", "script": "res://addons/asset_browser/providers/fab/fab_tab.gd"},
]

var editor: EditorInterface


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in PROVIDERS:
		var node = load(p["script"]).new()
		node.name = p["name"]
		node.editor = editor
		add_child(node)
		set_tab_title(get_child_count() - 1, p["title"])
	connect("tab_changed", self, "_on_tab_changed")


func on_shown() -> void:
	_on_tab_changed(current_tab)


func _on_tab_changed(idx: int) -> void:
	if idx < 0 or idx >= get_child_count():
		return
	var node = get_child(idx)
	if node.has_method("on_shown"):
		node.on_shown()
