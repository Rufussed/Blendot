@tool
extends RefCounted
## "Save as .blend Asset...": turns a MeshInstance3D (and the Blender objects
## Blendot made as its children) into a .blend file in the project, and replaces
## the node with an instance of it that Godot imports directly.

const MeshNodeEditor := preload("res://addons/blendot/mesh_node_editor.gd")
const References := preload("res://addons/blendot/references.gd")
const BlenderSetup := preload("res://addons/blendot/blender_setup.gd")
const IMPORT_TIMEOUT_MSEC := 120000

var _session: Node
var _mesh_editor: RefCounted


func _init(session: Node, mesh_editor: RefCounted) -> void:
	_session = session
	_mesh_editor = mesh_editor


func start(node: MeshInstance3D) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.blend", "Blender file")
	dialog.title = "Save %s as .blend asset" % node.name
	var dir := root.scene_file_path.get_base_dir() if root.scene_file_path else "res://"
	dialog.current_path = dir.path_join(String(node.name).validate_filename() + ".blend")
	dialog.file_selected.connect(func(path): _confirm(node, path))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered_ratio(dialog, 0.6)


func _confirm(node: MeshInstance3D, blend: String) -> void:
	if FileAccess.file_exists(blend):
		_alert("%s already exists. Choose another name." % blend)
		return
	var file_name := blend.get_file().get_basename()
	var lines := PackedStringArray([
		"Save %s as %s and replace it with an instance of that file?" % [node.name, blend], "",
		"- Position, rotation and scale stay the same.",
		"- Children you added in Godot move onto the new instance.",
		"- References to it in this scene (exported properties, animation tracks) are updated.",
		"- Everyone opening this project will need Blender installed."])
	if node.get_script():
		lines.append("- Its script (%s) won't carry over; reattach it to the new node."
			% node.get_script().resource_path.get_file())
	var signal_count := 0
	for sig in node.get_signal_list():
		for c in node.get_signal_connection_list(sig.name):
			if c.flags & CONNECT_PERSIST:
				signal_count += 1
	for c in node.get_incoming_connections():
		if c.flags & CONNECT_PERSIST:
			signal_count += 1
	if signal_count:
		lines.append("- Its %d signal connection(s) won't carry over." % signal_count)

	var box := VBoxContainer.new()
	var text := Label.new()
	text.text = "\n".join(lines)
	box.add_child(text)
	var rename := CheckBox.new()
	var renaming := file_name != String(node.name)
	var mentions := References.script_mentions(node.name) if renaming else PackedStringArray()
	if renaming:
		rename.text = "Rename node %s to %s" % [node.name, file_name]
		rename.button_pressed = mentions.is_empty()  # don't surprise scripts that use it
		box.add_child(rename)
		if mentions:
			var warn := Label.new()
			warn.text = ("Scripts that may refer to it by name (not changed; update them "
				+ "yourself if you rename):\n  " + "\n  ".join(mentions))
			warn.add_theme_color_override("font_color",
				EditorInterface.get_editor_theme().get_color("warning_color", "Editor"))
			box.add_child(warn)

	var dialog := ConfirmationDialog.new()
	dialog.title = "Blendot: save as .blend asset"
	dialog.add_child(box)
	dialog.ok_button_text = "Save and Replace"
	dialog.confirmed.connect(func(): _run(node, blend, renaming and rename.button_pressed))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)


func _run(node: MeshInstance3D, blend: String, rename: bool) -> void:
	var blend_abs := ProjectSettings.globalize_path(blend)
	DirAccess.make_dir_recursive_absolute(blend_abs.get_base_dir())

	# The node's own Blender file already holds its hierarchy; otherwise build one.
	var glb_abs := ProjectSettings.globalize_path(_mesh_editor._glb_path(node))
	var sidecar_abs := glb_abs + ".blend"
	if _session.is_open(sidecar_abs):
		_alert("%s is open in Blender. Save and close it first." % node.name)
		return
	if FileAccess.file_exists(sidecar_abs):
		DirAccess.copy_absolute(sidecar_abs, blend_abs)
	else:
		DirAccess.make_dir_recursive_absolute(glb_abs.get_base_dir())
		if _mesh_editor._export_glb(node, glb_abs) != OK:
			_alert("Exporting %s to glTF failed." % node.name)
			return
		if not BlenderSetup.ensure():
			return
		var output := []
		var code := BlenderSetup.execute(PackedStringArray([
			"-b", "--factory-startup",
			"--python", ProjectSettings.globalize_path(_session.BRIDGE),
			"--", "--mode", "convert", "--target", glb_abs, "--blend", blend_abs,
		]), output)
		if code != 0 or not FileAccess.file_exists(blend):
			_alert("Blender could not create %s:\n\n%s" % [blend, "\n".join(output).right(1500)])
			return

	var scene := await _import(blend)
	if scene == null:
		_alert("Godot didn't import %s. Check that Blender import is enabled in\n"
			% blend + "Editor Settings > FileSystem > Import > Blender.")
		return
	if not is_instance_valid(node) or not node.is_inside_tree():
		_alert("%s was saved, but the node is gone, so nothing was replaced." % blend)
		return
	_replace(node, scene, rename)


## Waits for Godot to import the new file, then loads it.
func _import(blend: String) -> PackedScene:
	var fs := EditorInterface.get_resource_filesystem()
	var tree := _session.get_tree()
	var start := Time.get_ticks_msec()
	fs.scan()
	while Time.get_ticks_msec() - start < IMPORT_TIMEOUT_MSEC:
		await tree.create_timer(0.25).timeout
		if fs.is_scanning() or not FileAccess.file_exists(blend + ".import"):
			continue
		if ResourceLoader.exists(blend):
			return ResourceLoader.load(blend) as PackedScene
	return null


func _replace(node: MeshInstance3D, scene: PackedScene, rename: bool) -> void:
	var owner := node.owner if node.owner else node
	var parent := node.get_parent()
	var instance := scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	# Optionally named after the file, as if dragged in from the FileSystem dock.
	var new_name := StringName(scene.resource_path.get_file().get_basename()) if rename else node.name
	instance.transform = node.transform
	# Children added in Godot move over; Blendot's own are now inside the .blend.
	var movers := node.get_children().filter(func(c): return not c.has_meta(MeshNodeEditor.META_ID))
	var owned := {}
	for c in movers:
		owned[c] = [c] + c.find_children("*", "", true, false).filter(func(d): return d.owner == owner)

	# Nodes whose owner Godot clears when they leave the tree, to restore on undo.
	var node_owned := [node] + node.find_children("*", "", true, false).filter(
		func(d): return d.owner == owner and not movers.any(func(m): return m == d or m.is_ancestor_of(d)))
	var index := node.get_index()

	# Only built-in Node methods here: undo steps that call plugin code break if
	# the plugin is reloaded while they're still in the history.
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Blendot: replace %s with %s" % [node.name, scene.resource_path.get_file()],
		UndoRedo.MERGE_DISABLE, owner)
	undo.add_do_method(parent, "remove_child", node)
	for c in movers:
		undo.add_do_method(node, "remove_child", c)
	undo.add_do_method(parent, "add_child", instance)
	undo.add_do_method(parent, "move_child", instance, index)
	undo.add_do_method(instance, "set_name", new_name)  # a clash gets a number added
	undo.add_do_method(instance, "set_owner", owner)
	for c in movers:
		undo.add_do_method(instance, "add_child", c)
		for o in owned[c]:
			undo.add_do_method(o, "set_owner", owner)
	undo.add_do_reference(instance)

	undo.add_undo_method(parent, "remove_child", instance)
	for c in movers:
		undo.add_undo_method(instance, "remove_child", c)
	undo.add_undo_method(parent, "add_child", node)
	undo.add_undo_method(parent, "move_child", node, index)
	for o in node_owned:
		undo.add_undo_method(o, "set_owner", owner)
	for c in movers:
		undo.add_undo_method(node, "add_child", c)
		for o in owned[c]:
			undo.add_undo_method(o, "set_owner", owner)
	undo.add_undo_reference(node)

	var fixes := References.scene_fixes(node, instance, new_name)
	for f in fixes.props:
		undo.add_do_property(f[0], f[1], f[3])
		undo.add_undo_property(f[0], f[1], f[2])
	for t in fixes.tracks:
		undo.add_do_method(t[0], "track_set_path", t[1], t[3])
		undo.add_undo_method(t[0], "track_set_path", t[1], t[2])
	undo.commit_action()
	if fixes.readonly:
		_alert("These animations live in other files and still use the old path; "
			+ "update them yourself:\n" + "\n".join(fixes.readonly))
	EditorInterface.edit_node(instance)
	print("Blendot: replaced %s with an instance of %s (%d references updated)"
		% [node.name, scene.resource_path, fixes.props.size() + fixes.tracks.size()])


func _alert(text: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Blendot"
	dialog.dialog_text = text
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())
	EditorInterface.popup_dialog_centered(dialog)
