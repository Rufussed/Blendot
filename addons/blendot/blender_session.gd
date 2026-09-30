@tool
extends Node
## Creates/opens the sidecar .blend for an asset, launches Blender, and
## rescans the filesystem when Blender writes the asset back.

const SETTING_SIDECAR_DIR := "blendot/sidecar_dir"
const SETTING_ON_CHANGE := "blendot/on_external_change"
const SETTING_MODE := "blendot/mode"
const MODE_SIDECAR := 0
const MODE_CONVERT := 1
const ON_CHANGE_ASK := 0
const ON_CHANGE_USE_NEW := 1
const ON_CHANGE_KEEP_MINE := 2
const BRIDGE := "res://addons/blendot/blender/blendot_bridge.py"

const BlenderSetup := preload("res://addons/blendot/blender_setup.gd")

## abs path -> {"mtime": int, "on_change": Callable}, for files Blender writes.
var _watched := {}
## blend abs path -> pid of the Blender this editor session launched for it.
var _running := {}
var _timer: Timer


static func register_settings() -> void:
	BlenderSetup.migrate_old_setting()
	_project_setting(SETTING_SIDECAR_DIR, "res://.blendot",
		{"type": TYPE_STRING, "hint": PROPERTY_HINT_DIR})
	_project_setting(SETTING_MODE, MODE_SIDECAR,
		{"type": TYPE_INT, "hint": PROPERTY_HINT_ENUM,
		"hint_string": "Sidecar (keep FBX/glb; hidden .blend exports to it),Convert (replace FBX/glb with a .blend)"})
	_project_setting(SETTING_ON_CHANGE, ON_CHANGE_ASK,
		{"type": TYPE_INT, "hint": PROPERTY_HINT_ENUM,
		"hint_string": "Ask,Use New File,Keep My Blend"})


static func _project_setting(setting: String, default: Variant, info: Dictionary) -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default)
	ProjectSettings.set_initial_value(setting, default)
	ProjectSettings.set_as_basic(setting, true)  # visible without "Advanced Settings"
	info["name"] = setting
	ProjectSettings.add_property_info(info)


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(_poll)
	add_child(_timer)


func edit_file(res_path: String) -> void:
	var problem := _unsupported_reason(res_path)
	if problem:
		var dialog := AcceptDialog.new()
		dialog.title = "Blendot: can't open in Blender"
		dialog.dialog_text = problem
		dialog.visibility_changed.connect(func():
			if not dialog.visible: dialog.queue_free())
		EditorInterface.popup_dialog_centered(dialog)
		return
	var blend := sidecar_blend_path(res_path)
	var asset_abs := ProjectSettings.globalize_path(res_path)
	var blend_abs := ProjectSettings.globalize_path(blend)
	if is_open(blend_abs):
		_focus_existing(blend_abs)
		return

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


## Blender imports binary FBX 7.1 (7100) and newer only; Godot reads older
## and ASCII FBX, so such files can look fine in Godot yet fail in Blender.
func _unsupported_reason(res_path: String) -> String:
	if res_path.get_extension().to_lower() != "fbx":
		return ""
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return "Could not read %s." % res_path
	var magic := f.get_buffer(18).get_string_from_ascii()
	if magic != "Kaydara FBX Binary":
		return ("%s is a text (ASCII) FBX, which Blender can't import.\n"
			+ "Re-export it as binary FBX, or convert it to .glb.") % res_path.get_file()
	f.seek(23)
	var version := f.get_32()
	if version < 7100:
		return ("%s is FBX version %d.%d, but Blender only imports FBX 7.1 and newer.\n"
			+ "Re-export it from its source tool as FBX 7.x (2011 or later), or convert it to .glb.") \
			% [res_path.get_file(), version / 1000, version % 1000 / 100]
	return ""


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
	# A second Blender on the same .blend would overwrite the first one's saves.
	if is_open(blend_abs):
		watch(asset_abs, on_change)
		_focus_existing(blend_abs)
		return
	if not BlenderSetup.ensure():
		return
	DirAccess.make_dir_recursive_absolute(blend_abs.get_base_dir())
	_ensure_gdignore()
	if rebuild and FileAccess.file_exists(blend_abs):
		DirAccess.rename_absolute(blend_abs, blend_abs + ".bak")

	var args := PackedStringArray([
		"--python", ProjectSettings.globalize_path(BRIDGE),
		"--", "--target", asset_abs, "--blend", blend_abs, "--mode", mode,
	])
	var pid := BlenderSetup.spawn(args)
	if pid <= 0:
		BlenderSetup.show_dialog("Blendot couldn't start Blender.")
		return
	print("Blendot: editing %s in Blender (sidecar %s)" % [asset_abs, blend_abs])
	_running[blend_abs] = pid
	watch(asset_abs, on_change)


func is_open(blend_abs: String) -> bool:
	var pid: int = _running.get(blend_abs, 0)
	if pid > 0 and OS.is_process_running(pid):
		return true
	_running.erase(blend_abs)
	return false


## True if any Blender this plugin launched still has a Blendot file open.
func open_blend_files() -> Array:
	return _running.keys().filter(is_open)


func _focus_existing(blend_abs: String) -> void:
	var pid: int = _running[blend_abs]
	# Hyprland can raise a window by pid; elsewhere, just tell the user.
	if OS.has_environment("HYPRLAND_INSTANCE_SIGNATURE"):
		OS.execute("hyprctl", ["dispatch", "focuswindow", "pid:%d" % pid])
	EditorInterface.get_editor_toaster().push_toast(
		"Blendot: %s is already open in Blender." % blend_abs.get_file().trim_suffix(".blend"),
		EditorToaster.SEVERITY_INFO)


## Opens a .blend that Godot imports directly; Godot reimports it on each save.
func open_blend(res_path: String) -> void:
	var blend_abs := ProjectSettings.globalize_path(res_path)
	if is_open(blend_abs):
		_focus_existing(blend_abs)
		return
	if not BlenderSetup.ensure():
		return
	var pid := BlenderSetup.spawn(PackedStringArray([
		"--python", ProjectSettings.globalize_path(BRIDGE),
		"--", "--blend", blend_abs, "--mode", "plain"]))
	if pid <= 0:
		BlenderSetup.show_dialog("Blendot couldn't start Blender.")
		return
	_running[blend_abs] = pid
	watch(blend_abs, _rescan)


static func mode() -> int:
	return int(ProjectSettings.get_setting(SETTING_MODE, MODE_SIDECAR))


## Calls on_change(path) whenever the file at path is rewritten.
func watch(path: String, on_change: Callable) -> void:
	_watched[path] = {"mtime": FileAccess.get_modified_time(path), "on_change": on_change}
	_timer.start()


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
