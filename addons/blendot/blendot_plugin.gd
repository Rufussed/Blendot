@tool
extends EditorPlugin

const FileMenu := preload("res://addons/blendot/file_context_menu.gd")
const Launcher := preload("res://addons/blendot/launcher.gd")

var _file_menu: EditorContextMenuPlugin
var _launcher: Launcher


func _enter_tree() -> void:
	Launcher.register_settings()
	_launcher = Launcher.new()
	EditorInterface.get_base_control().add_child(_launcher)
	_file_menu = FileMenu.new(_launcher)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _file_menu)


func _exit_tree() -> void:
	remove_context_menu_plugin(_file_menu)
	_launcher.queue_free()
