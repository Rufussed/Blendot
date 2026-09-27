@tool
extends RefCounted
## Project > Tools > "Blendot: Clean Up Unused Blender Files". Finds sidecar
## .blend/.glb files and saved meshes that nothing uses any more, lists them,
## and moves them to the system trash on confirmation.

const MeshNodeEditor := preload("res://addons/blendot/mesh_node_editor.gd")
const SIDECAR_SUFFIXES := [".glb", ".glb.blend", ".glb.blend1", ".glb.blend.json", ".glb.blend.bak"]

var _launcher: Node


func _init(launcher: Node) -> void:
	_launcher = launcher


func run() -> void:
	var unused := find_unused()
	var dialog := ConfirmationDialog.new()
	dialog.title = "Blendot: clean up unused Blender files"
	if unused.is_empty():
		dialog.dialog_text = "No unused Blendot files found."
		dialog.get_cancel_button().hide()
	else:
		var total := 0
		var lines := PackedStringArray()
		for path in unused:
			var size := FileAccess.get_file_as_bytes(path).size()
			total += size
			lines.append("%s  (%s)" % [path.trim_prefix("res://"), String.humanize_size(size)])
		dialog.dialog_text = ("These %d files (%s) aren't used by any saved or open scene:\n\n%s\n\n"
			+ "Move them to the trash?") % [unused.size(), String.humanize_size(total),
			"\n".join(lines)]
		dialog.ok_button_text = "Move to Trash"
		dialog.confirmed.connect(_trash.bind(unused))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered_clamped(dialog, Vector2i(800, 500))


func find_unused() -> Array[String]:
	var sidecar_dir: String = ProjectSettings.get_setting(_launcher.SETTING_SIDECAR_DIR, "res://.blendot")
	var mesh_dir: String = ProjectSettings.get_setting(MeshNodeEditor.SETTING_MESH_DIR, "res://blendot_meshes")
	_load_project_text([sidecar_dir, mesh_dir])
	var open_scenes := _open_scene_state()
	var busy: Array = _launcher.open_blend_files().map(ProjectSettings.localize_path)
	var unused: Array[String] = []

	# Node sidecars: <name>_<edit id>.glb (+ .blend ...), used while a scene
	# (saved or open) still has a node carrying that edit id.
	for path in _files_in(sidecar_dir.path_join("nodes")):
		var stem := _sidecar_stem(path)
		var id := stem.get_slice("_", stem.get_slice_count("_") - 1)
		if _referenced(id) or open_scenes.ids.has(id) or busy.has(_blend_of(path)):
			continue
		unused.append(path)

	# File sidecars: <sidecar dir>/<asset path>.blend, used while the asset exists.
	for path in _files_in(sidecar_dir):
		if path.begins_with(sidecar_dir.path_join("nodes") + "/") or path.get_file() == ".gdignore":
			continue
		var blend := _blend_of(path)
		var asset := "res://" + blend.trim_prefix(sidecar_dir + "/").trim_suffix(".blend")
		if not FileAccess.file_exists(asset) and not busy.has(blend):
			unused.append(path)

	# Saved meshes: used while any scene/resource references them by path or UID,
	# or an open scene uses them.
	for path in _files_in(mesh_dir):
		if not path.ends_with(".res"):
			continue
		var uid := ResourceUID.id_to_text(ResourceLoader.get_resource_uid(path))
		if _referenced(path) or (uid != "uid://<invalid>" and _referenced(uid)) \
				or open_scenes.meshes.has(path):
			continue
		unused.append(path)
	return unused


## The .blend a sidecar file belongs to (x.blend.json, x.blend1, x.blend.bak -> x.blend).
func _blend_of(path: String) -> String:
	if path.ends_with(".glb"):
		return path + ".blend"
	for suffix in [".json", "1", ".bak"]:
		if path.ends_with(".blend" + suffix):
			return path.trim_suffix(suffix)
	return path


func _sidecar_stem(path: String) -> String:
	for suffix in SIDECAR_SUFFIXES:
		if path.ends_with(suffix):
			return path.trim_suffix(suffix)
	return path.get_basename()


## Edit ids and mesh paths used by scenes open in the editor (maybe unsaved).
func _open_scene_state() -> Dictionary:
	var ids := {}
	var meshes := {}
	for root in EditorInterface.get_open_scene_roots():
		for n in [root] + root.find_children("*", "", true, false):
			if n.has_meta(MeshNodeEditor.META_EDIT_ID):
				ids[n.get_meta(MeshNodeEditor.META_EDIT_ID)] = true
			var mesh = n.get("mesh")
			if mesh is Resource and mesh.resource_path:
				meshes[mesh.resource_path] = true
	return {"ids": ids, "meshes": meshes}


var _text := ""  # every .tscn/.tres in the project
var _hex := ""   # every binary .scn/.res, hex-encoded (they contain NUL bytes)


func _load_project_text(skip_dirs: Array) -> void:
	var text := PackedStringArray()
	var hex := PackedStringArray()
	for path in _files_in("res://", skip_dirs):
		match path.get_extension():
			"tscn", "tres":
				text.append(FileAccess.get_file_as_string(path))
			"scn", "res":
				hex.append(FileAccess.get_file_as_bytes(path).hex_encode())
	_text = "\n".join(text)
	_hex = "|".join(hex)


func _referenced(needle: String) -> bool:
	return _text.contains(needle) or _hex.contains(needle.to_ascii_buffer().hex_encode())


func _files_in(dir: String, skip_dirs: Array = []) -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	da.include_hidden = true
	for f in da.get_files():
		out.append(dir.path_join(f))
	for sub in da.get_directories():
		var sub_path := dir.path_join(sub)
		if sub_path in skip_dirs or sub_path == "res://.godot" or sub_path == "res://addons":
			continue
		out.append_array(_files_in(sub_path, skip_dirs))
	return out


func _trash(paths: Array[String]) -> void:
	var failed := PackedStringArray()
	for path in paths:
		if OS.move_to_trash(ProjectSettings.globalize_path(path)) != OK:
			failed.append(path)
	EditorInterface.get_resource_filesystem().scan()
	if failed:
		push_error("Blendot: could not move to trash:\n" + "\n".join(failed))
	else:
		print("Blendot: moved %d unused files to the trash." % paths.size())
