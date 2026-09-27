@tool
extends Node
## Creates/opens the sidecar .blend for an asset, launches Blender, and
## rescans the filesystem when Blender writes the asset back.

const SETTING_BLENDER := "blendot/blender_path"
const SETTING_GODOT_BLENDER := "filesystem/import/blender/blender_path"
const SETTING_SIDECAR_DIR := "blendot/sidecar_dir"
const SETTING_ON_CHANGE := "blendot/on_external_change"
const ON_CHANGE_ASK := 0
const ON_CHANGE_USE_NEW := 1
const ON_CHANGE_KEEP_MINE := 2
const BRIDGE := "res://addons/blendot/blender/blendot_bridge.py"

## abs path -> {"mtime": int, "on_change": Callable}, for files Blender writes.
var _watched := {}
var _timer: Timer


static func register_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(SETTING_BLENDER):
		es.set_setting(SETTING_BLENDER, "")
	es.set_initial_value(SETTING_BLENDER, "", false)
	es.add_property_info({"name": SETTING_BLENDER, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE})

	_project_setting(SETTING_SIDECAR_DIR, "res://.blendot",
		{"type": TYPE_STRING, "hint": PROPERTY_HINT_DIR})
	_project_setting(SETTING_ON_CHANGE, ON_CHANGE_ASK,
		{"type": TYPE_INT, "hint": PROPERTY_HINT_ENUM,
		"hint_string": "Ask,Use New File,Keep My Blend"})


static func _project_setting(setting: String, default: Variant, info: Dictionary) -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default)
	ProjectSettings.set_initial_value(setting, default)
	info["name"] = setting
	ProjectSettings.add_property_info(info)


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(_poll)
	add_child(_timer)


func edit_file(res_path: String) -> void:
	var blend := sidecar_blend_path(res_path)
	var asset_abs := ProjectSettings.globalize_path(res_path)
	var blend_abs := ProjectSettings.globalize_path(blend)

	if not FileAccess.file_exists(blend):
		launch(asset_abs, blend_abs, false)
		return
	if FileAccess.get_sha256(res_path) == _recorded_hash(blend):
		launch(asset_abs, blend_abs, false)
		return

	match int(ProjectSettings.get_setting(SETTING_ON_CHANGE, ON_CHANGE_ASK)):
		ON_CHANGE_USE_NEW:
			launch(asset_abs, blend_abs, true)
		ON_CHANGE_KEEP_MINE:
			launch(asset_abs, blend_abs, false)
		_:
			_ask_stale(res_path, asset_abs, blend_abs)


func sidecar_blend_path(res_path: String) -> String:
	var dir: String = ProjectSettings.get_setting(SETTING_SIDECAR_DIR, "res://.blendot")
	return dir.path_join(res_path.trim_prefix("res://")) + ".blend"


func _recorded_hash(blend: String) -> String:
	var text := FileAccess.get_file_as_string(blend + ".json")
	var data = JSON.parse_string(text) if text else null
	return data.get("target_sha256", "") if data is Dictionary else ""


func _ask_stale(res_path: String, asset_abs: String, blend_abs: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Blendot: asset changed outside Blender"
	dialog.dialog_text = ("%s has changed since your .blend last exported it\n"
		+ "(a teammate or another tool may have updated it).\n\n"
		+ "Use New File: rebuild the .blend from it (old .blend kept as .blend.bak).\n"
		+ "Keep My Blend: open your .blend; your next save overwrites their changes.") % res_path
	dialog.ok_button_text = "Use New File"
	dialog.add_button("Keep My Blend", true, "keep")
	dialog.confirmed.connect(func(): launch(asset_abs, blend_abs, true))
	dialog.custom_action.connect(func(_a):
		dialog.hide()
		launch(asset_abs, blend_abs, false))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)


func launch(asset_abs: String, blend_abs: String, rebuild: bool,
		on_change: Callable = _rescan, mode := "file") -> void:
	DirAccess.make_dir_recursive_absolute(blend_abs.get_base_dir())
	_ensure_gdignore()
	if rebuild and FileAccess.file_exists(blend_abs):
		DirAccess.rename_absolute(blend_abs, blend_abs + ".bak")

	var args := PackedStringArray([
		"--python", ProjectSettings.globalize_path(BRIDGE),
		"--", "--target", asset_abs, "--blend", blend_abs, "--mode", mode,
	])
	var pid := OS.create_process(_blender_path(), args)
	if pid <= 0:
		push_error("Blendot: could not start Blender at '%s'. Set Editor Settings > %s."
			% [_blender_path(), SETTING_BLENDER])
		return
	print("Blendot: editing %s in Blender (sidecar %s)" % [asset_abs, blend_abs])
	watch(asset_abs, on_change)


## Calls on_change(path) whenever the file at path is rewritten.
func watch(path: String, on_change: Callable) -> void:
	_watched[path] = {"mtime": FileAccess.get_modified_time(path), "on_change": on_change}
	_timer.start()


func _blender_path() -> String:
	var es := EditorInterface.get_editor_settings()
	for key in [SETTING_BLENDER, SETTING_GODOT_BLENDER]:
		if es.has_setting(key) and str(es.get_setting(key)) != "":
			return es.get_setting(key)
	return "blender"


func _ensure_gdignore() -> void:
	var dir: String = ProjectSettings.get_setting(SETTING_SIDECAR_DIR, "res://.blendot")
	var path := dir.path_join(".gdignore")
	if not FileAccess.file_exists(path):
		FileAccess.open(path, FileAccess.WRITE)


func _poll() -> void:
	var rescan := false
	for path in _watched.keys():
		var entry: Dictionary = _watched[path]
		if not FileAccess.file_exists(path):
			continue  # deleted or mid-rewrite; wait for it to come back
		var mtime := FileAccess.get_modified_time(path)
		if mtime == entry.mtime:
			continue
		entry.mtime = mtime
		if entry.on_change == _rescan:
			rescan = true  # one scan covers every changed asset
		else:
			entry.on_change.call(path)
	if rescan:
		_rescan("")


func _rescan(_path: String) -> void:
	EditorInterface.get_resource_filesystem().scan()
