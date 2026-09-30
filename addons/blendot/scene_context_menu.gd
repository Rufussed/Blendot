@tool
extends EditorContextMenuPlugin

const BlenderSetup := preload("res://addons/blendot/blender_setup.gd")

var _editor: RefCounted
var _to_asset: RefCounted
## Opens a model file in Blender, as the FileSystem dock's "Edit in Blender" does.
var _edit_file: Callable
var _file_types: Array


func _init(mesh_node_editor: RefCounted, node_to_asset: RefCounted,
		edit_file: Callable, file_types: Array) -> void:
	_editor = mesh_node_editor
	_to_asset = node_to_asset
	_edit_file = edit_file
	_file_types = file_types


func _popup_menu(_paths: PackedStringArray) -> void:
	var theme := EditorInterface.get_editor_theme()
	if _selected_model_instance() != "":
		add_context_menu_item("Edit in Blender", _on_edit_instance, BlenderSetup.menu_icon())
		return
	var node := _selected_mesh_node()
	if node == null or node.mesh == null:
		return
	add_context_menu_item("Edit in Blender", _on_edit, BlenderSetup.menu_icon())
	add_context_menu_item("Save as .blend Asset...", _on_save_asset,
		theme.get_icon("PackedScene", "EditorIcons"))


func _selected_mesh_node() -> MeshInstance3D:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	return selected[0] as MeshInstance3D if selected.size() == 1 else null


## The model file behind the selected node, if it's an instance of one
## (e.g. a .glb dragged into the scene); otherwise "".
func _selected_model_instance() -> String:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.size() != 1:
		return ""
	var path: String = selected[0].scene_file_path
	return path if path.get_extension().to_lower() in _file_types else ""


func _on_edit_instance(_paths: Array) -> void:
	var path := _selected_model_instance()
	if path:
		_edit_file.call(path)


func _on_edit(_paths: Array) -> void:
	var node := _selected_mesh_node()
	if node:
		_editor.edit(node)


func _on_save_asset(_paths: Array) -> void:
	var node := _selected_mesh_node()
	if node:
		_to_asset.start(node)
