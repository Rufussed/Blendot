@tool
extends EditorContextMenuPlugin

var _editor: RefCounted


func _init(mesh_node_editor: RefCounted) -> void:
	_editor = mesh_node_editor


func _popup_menu(_paths: PackedStringArray) -> void:
	var node := _selected_mesh_node()
	if node == null or node.mesh == null:
		return
	var icon := EditorInterface.get_editor_theme().get_icon("Edit", "EditorIcons")
	add_context_menu_item("Edit in Blender", _on_edit, icon)


func _selected_mesh_node() -> MeshInstance3D:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	return selected[0] as MeshInstance3D if selected.size() == 1 else null


func _on_edit(_paths: Array) -> void:
	var node := _selected_mesh_node()
	if node:
		_editor.edit(node)
