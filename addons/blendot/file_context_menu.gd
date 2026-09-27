@tool
extends EditorContextMenuPlugin

const SUPPORTED := ["fbx", "glb", "gltf", "obj"]

var _launcher: Node


func _init(launcher: Node) -> void:
	_launcher = launcher


func _popup_menu(paths: PackedStringArray) -> void:
	if paths.size() != 1:
		return
	if paths[0].get_extension().to_lower() not in SUPPORTED:
		return
	var icon := EditorInterface.get_editor_theme().get_icon("Edit", "EditorIcons")
	add_context_menu_item("Edit in Blender", _on_edit, icon)


func _on_edit(paths: PackedStringArray) -> void:
	_launcher.edit_file(paths[0])
