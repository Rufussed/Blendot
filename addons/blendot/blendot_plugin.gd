@tool
extends EditorPlugin

const FileMenu := preload("res://addons/blendot/file_context_menu.gd")
const SceneMenu := preload("res://addons/blendot/scene_context_menu.gd")
const Launcher := preload("res://addons/blendot/launcher.gd")
const MeshNodeEditor := preload("res://addons/blendot/mesh_node_editor.gd")

var _file_menu: EditorContextMenuPlugin
var _scene_menu: EditorContextMenuPlugin
var _launcher: Launcher


func _enter_tree() -> void:
	Launcher.register_settings()
	MeshNodeEditor.register_settings()
	_launcher = Launcher.new()
	EditorInterface.get_base_control().add_child(_launcher)
	_file_menu = FileMenu.new(_launcher)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _file_menu)
	_scene_menu = SceneMenu.new(MeshNodeEditor.new(_launcher))
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_menu)


func _exit_tree() -> void:
	remove_context_menu_plugin(_file_menu)
	remove_context_menu_plugin(_scene_menu)
	_launcher.queue_free()
