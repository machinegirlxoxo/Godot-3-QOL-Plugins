tool
extends MenuButton
# "Texture Quality" menu for the 3D editor toolbar.
#  - Quality level: which baked tier the editor shows (default: Lowest, which costs nothing).
#    The chosen level is also written to the project settings, so the game uses it when you press Play.
#  - Game VRAM Budget: written to the project settings the game reads.
#  - Distance LOD (game): on/off switch for swapping tiers by camera distance (project setting `texture_quality/distance_lod`).

const LEVELS = [[0, "Highest"], [1, "High"], [2, "Medium"], [3, "Low"], [99, "Lowest (editor default)"]]
const LOD_ID = 100
const BUDGETS = [[0, "Unlimited"], [512, "512 MB"], [1024, "1 GB"], [2048, "2 GB"], [4096, "4 GB"]]

var _settings: EditorSettings
var _level = 99
var _budget_menu: PopupMenu


func setup(editor_settings: EditorSettings) -> void:
	_settings = editor_settings


func _init() -> void:
	text = "Texture Quality"
	hint_tooltip = "Preview baked texture tiers in the editor and set game quality."


func _ready() -> void:
	var popup = get_popup()
	popup.add_separator("Quality (editor + game)")
	for entry in LEVELS:
		popup.add_radio_check_item(entry[1], entry[0])
	popup.add_separator()

	_budget_menu = PopupMenu.new()
	_budget_menu.name = "budget"
	popup.add_child(_budget_menu)
	for i in range(BUDGETS.size()):
		_budget_menu.add_radio_check_item(BUDGETS[i][1], i)
	popup.add_submenu_item("Game VRAM Budget", "budget")
	popup.add_separator()
	popup.add_check_item("Distance LOD (game)", LOD_ID)
	popup.connect("id_pressed", self, "_on_id_pressed")
	_budget_menu.connect("id_pressed", self, "_on_budget_pressed")

	if _settings != null:
		_level = int(_settings.get_project_metadata("texture_quality", "level", 99))
	_select_level(_level, false)
	_refresh_budget_checks()
	_refresh_lod_check()


func _select_level(level: int, persist_to_game: bool = true) -> void:
	_level = level
	Engine.set_meta("tq_editor_level", level)
	var popup = get_popup()
	for entry in LEVELS:
		popup.set_item_checked(popup.get_item_index(entry[0]), entry[0] == level)
	if _settings != null:
		_settings.set_project_metadata("texture_quality", "level", level)
	if persist_to_game:
		ProjectSettings.set_setting("texture_quality/quality", level)
		ProjectSettings.save()
		_clear_user_override("quality")
	var alive = []
	var list = []
	if Engine.has_meta("tq_editor_textures"):
		list = Engine.get_meta("tq_editor_textures")
	for w in list:
		var tex = w.get_ref()
		if tex != null:
			alive.append(w)
			tex.apply_tier(level)
	Engine.set_meta("tq_editor_textures", alive)


func _on_id_pressed(id: int) -> void:
	if id == LOD_ID:
		var on = true
		if ProjectSettings.has_setting("texture_quality/distance_lod"):
			on = bool(ProjectSettings.get_setting("texture_quality/distance_lod"))
		ProjectSettings.set_setting("texture_quality/distance_lod", not on)
		ProjectSettings.save()
		_clear_user_override("distance_lod")
		_refresh_lod_check()
		return
	_select_level(id)


func _refresh_lod_check() -> void:
	var on = true
	if ProjectSettings.has_setting("texture_quality/distance_lod"):
		on = bool(ProjectSettings.get_setting("texture_quality/distance_lod"))
	var popup = get_popup()
	popup.set_item_checked(popup.get_item_index(LOD_ID), on)


func _on_budget_pressed(index: int) -> void:
	ProjectSettings.set_setting("texture_quality/vram_budget_mb", BUDGETS[index][0])
	ProjectSettings.save()
	_clear_user_override("vram_budget_mb")
	_refresh_budget_checks()


func _refresh_budget_checks() -> void:
	var current = 0
	if ProjectSettings.has_setting("texture_quality/vram_budget_mb"):
		current = int(ProjectSettings.get_setting("texture_quality/vram_budget_mb"))
	for i in range(BUDGETS.size()):
		_budget_menu.set_item_checked(i, BUDGETS[i][0] == current)


# A value saved from a script would otherwise override what the menu just set.
func _clear_user_override(key: String) -> void:
	var cfg = ConfigFile.new()
	if cfg.load("user://texture_quality.cfg") == OK and cfg.has_section_key("texture_quality", key):
		cfg.erase_section_key("texture_quality", key)
		cfg.save("user://texture_quality.cfg")
