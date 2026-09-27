@tool
extends EditorContextMenuPlugin

var _editor: RefCounted
var _to_asset: RefCounted


func _init(mesh_node_editor: RefCounted, node_to_asset: RefCounted) -> void:
	_editor = mesh_node_editor
	_to_asset = node_to_asset


func _popup_menu(_paths: PackedStringArray) -> void:
	var node := _selected_mesh_node()
	if node == null or node.mesh == null:
		return
	var theme := EditorInterface.get_editor_theme()
	add_context_menu_item("Edit in Blender", _on_edit, theme.get_icon("Edit", "EditorIcons"))
	add_context_menu_item("Save as .blend Asset...", _on_save_asset,
		theme.get_icon("PackedScene", "EditorIcons"))


func _selected_mesh_node() -> MeshInstance3D:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	return selected[0] as MeshInstance3D if selected.size() == 1 else null


func _on_edit(_paths: Array) -> void:
	var node := _selected_mesh_node()
	if node:
		_editor.edit(node)


func _on_save_asset(_paths: Array) -> void:
	var node := _selected_mesh_node()
	if node:
		_to_asset.start(node)
