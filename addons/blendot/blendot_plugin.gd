@tool
extends EditorPlugin

const FileMenu := preload("res://addons/blendot/file_context_menu.gd")
const SceneMenu := preload("res://addons/blendot/scene_context_menu.gd")
const Launcher := preload("res://addons/blendot/launcher.gd")
const MeshNodeEditor := preload("res://addons/blendot/mesh_node_editor.gd")
const Cleanup := preload("res://addons/blendot/cleanup.gd")
const Converter := preload("res://addons/blendot/converter.gd")
const NodeToAsset := preload("res://addons/blendot/node_to_asset.gd")
const ImportDialogButton := preload("res://addons/blendot/import_dialog_button.gd")
const CLEANUP_MENU := "Blendot: Clean Up Unused Blender Files..."
const SETTINGS_MENU := "Blendot: Settings..."

var _file_menu: EditorContextMenuPlugin
var _scene_menu: EditorContextMenuPlugin
var _launcher: Launcher
var _cleanup: Cleanup
var _converter: Converter
var _import_button: ImportDialogButton


func _enter_tree() -> void:
	Launcher.register_settings()
	MeshNodeEditor.register_settings()
	_launcher = Launcher.new()
	EditorInterface.get_base_control().add_child(_launcher)
	_converter = Converter.new(_launcher)
	_file_menu = FileMenu.new(_launcher, _converter)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _file_menu)
	var mesh_editor := MeshNodeEditor.new(_launcher)
	_scene_menu = SceneMenu.new(mesh_editor, NodeToAsset.new(_launcher, mesh_editor))
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_menu)
	_cleanup = Cleanup.new(_launcher)
	add_tool_menu_item(CLEANUP_MENU, _cleanup.run)
	add_tool_menu_item(SETTINGS_MENU, _open_settings)
	_import_button = ImportDialogButton.new(_file_menu.edit_path, FileMenu.SUPPORTED)
	_import_button.attach.call_deferred()


func _exit_tree() -> void:
	remove_context_menu_plugin(_file_menu)
	remove_context_menu_plugin(_scene_menu)
	remove_tool_menu_item(CLEANUP_MENU)
	remove_tool_menu_item(SETTINGS_MENU)
	if _import_button:
		_import_button.detach()
	_launcher.queue_free()


## Opens Project Settings filtered to "blendot". Godot has no API for this, so
## it finds the dialog's filter box; if that ever changes, it falls back to a hint.
func _open_settings() -> void:
	var toaster := EditorInterface.get_editor_toaster()
	toaster.push_toast("Blendot: the Blender path is in Editor Settings > Blendot.",
		EditorToaster.SEVERITY_INFO)
	var dialogs := EditorInterface.get_base_control().find_children("*", "ProjectSettingsEditor", true, false)
	if dialogs.is_empty():
		toaster.push_toast("Blendot: open Project > Project Settings and search for \"blendot\".",
			EditorToaster.SEVERITY_INFO)
		return
	var dialog: Window = dialogs[0]
	dialog.popup_centered_clamped(Vector2i(900, 700), 0.8)
	var tabs := dialog.find_children("*", "TabContainer", false, false)
	if tabs:
		tabs[0].current_tab = 0
	for edit in dialog.find_children("*", "LineEdit", true, false):
		if edit.placeholder_text == "Filter Settings":
			edit.text = "blendot"
			edit.text_changed.emit(edit.text)
			return
