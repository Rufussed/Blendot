@tool
extends RefCounted
## Replaces an FBX/glTF asset with a .blend that Godot imports directly, keeping
## its UID (and so every reference to it) and its import settings.

## Import settings that only mean something to the old importer.
const FORMAT_PARAM_PREFIXES := ["fbx/", "gltf/"]
const CONVERTIBLE := ["fbx", "glb", "gltf"]

var _launcher: Node


func _init(launcher: Node) -> void:
	_launcher = launcher


static func can_convert(res_path: String) -> bool:
	return res_path.get_extension().to_lower() in CONVERTIBLE


## Asks first, then converts; open_after launches Blender on the new .blend.
func confirm_and_convert(res_path: String, open_after: bool) -> void:
	var blend := blend_path_for(res_path)
	if FileAccess.file_exists(blend):
		_alert("%s already exists. Remove or rename it first." % blend.get_file())
		return
	var problem: String = _launcher._unsupported_reason(res_path)
	if problem:
		_alert(problem)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Blendot: convert to .blend"
	dialog.dialog_text = ("Replace %s with %s?\n\n"
		+ "- All scenes are saved first.\n"
		+ "- References keep working: the .blend takes over the file's UID and import settings.\n"
		+ "- %s is moved to the trash.\n"
		+ "- Everyone opening this project will need Blender installed and set in\n"
		+ "  Editor Settings > FileSystem > Import > Blender.") \
		% [res_path.get_file(), blend.get_file(), res_path.get_file()]
	dialog.ok_button_text = "Convert"
	dialog.confirmed.connect(func():
		if convert_asset(res_path) and open_after:
			_launcher.open_blend(blend))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)


static func blend_path_for(res_path: String) -> String:
	return res_path.get_basename() + ".blend"


## Returns true on success.
func convert_asset(res_path: String) -> bool:
	EditorInterface.save_all_scenes()
	var blend := blend_path_for(res_path)
	var blend_abs := ProjectSettings.globalize_path(blend)

	# 1. The .blend: an up-to-date sidecar already holds the user's Blender work.
	var sidecar: String = _launcher.sidecar_blend_path(res_path)
	var sidecar_current: bool = FileAccess.file_exists(sidecar) \
		and FileAccess.get_sha256(res_path) == _launcher._recorded_hash(sidecar)
	if sidecar_current:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(sidecar), blend_abs)
	else:
		var output := []
		var code := OS.execute(_launcher._blender_path(), PackedStringArray([
			"-b", "--factory-startup",
			"--python", ProjectSettings.globalize_path(_launcher.BRIDGE),
			"--", "--mode", "convert",
			"--target", ProjectSettings.globalize_path(res_path), "--blend", blend_abs,
		]), output, true)
		if code != 0 or not FileAccess.file_exists(blend):
			_alert("Blender could not convert %s:\n\n%s" % [res_path.get_file(),
				"\n".join(output).right(1500)])
			return false

	# 2. The .import: same UID, same settings, minus the old importer's own.
	var old_import := ConfigFile.new()
	if old_import.load(res_path + ".import") != OK:
		_alert("Could not read %s.import." % res_path)
		DirAccess.remove_absolute(blend_abs)
		return false
	var new_import := ConfigFile.new()
	new_import.set_value("remap", "importer", "scene")
	new_import.set_value("remap", "importer_version", 1)
	new_import.set_value("remap", "type", "PackedScene")
	new_import.set_value("remap", "uid", old_import.get_value("remap", "uid", ""))
	for key in old_import.get_section_keys("params"):
		if not FORMAT_PARAM_PREFIXES.any(func(p): return key.begins_with(p)):
			new_import.set_value("params", key, old_import.get_value("params", key))
	new_import.save(blend + ".import")

	# 3. Retire the old file (trash, so it can be recovered).
	OS.move_to_trash(ProjectSettings.globalize_path(res_path))
	OS.move_to_trash(ProjectSettings.globalize_path(res_path + ".import"))

	# 4. Point saved scenes/resources at the new path (the UID already resolves,
	# this just avoids "path mismatch" warnings).
	var changed := _replace_path_in_files(res_path, blend)
	var scripts := _scripts_mentioning(res_path)

	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	for scene in changed:
		if scene in EditorInterface.get_open_scenes():
			EditorInterface.reload_scene_from_path(scene)

	var summary := "Converted %s to %s." % [res_path.get_file(), blend.get_file()]
	if changed:
		summary += "\nUpdated %d scene/resource file(s)." % changed.size()
	if scripts:
		summary += ("\n\nThese scripts still mention the old path; update them by hand:\n"
			+ "\n".join(scripts))
		_alert(summary)
	print("Blendot: " + summary.replace("\n", " "))
	return true


func _replace_path_in_files(old_path: String, new_path: String) -> Array[String]:
	var changed: Array[String] = []
	for path in _project_files(["tscn", "tres"]):
		var text := FileAccess.get_file_as_string(path)
		if not text.contains('"%s"' % old_path):
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(text.replace('"%s"' % old_path, '"%s"' % new_path))
		f.close()
		changed.append(path)
	return changed


func _scripts_mentioning(old_path: String) -> Array[String]:
	var out: Array[String] = []
	for path in _project_files(["gd", "cs"]):
		if FileAccess.get_file_as_string(path).contains(old_path):
			out.append(path)
	return out


func _project_files(extensions: Array, dir := "res://") -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		if f.get_extension() in extensions:
			out.append(dir.path_join(f))
	for sub in da.get_directories():
		if not sub.begins_with(".") and dir.path_join(sub) != "res://addons":
			out.append_array(_project_files(extensions, dir.path_join(sub)))
	return out


func _alert(text: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Blendot"
	dialog.dialog_text = text
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)
