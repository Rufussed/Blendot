@tool
extends EditorContextMenuPlugin

const SUPPORTED := ["fbx", "glb", "gltf", "obj", "blend"]
const Launcher := preload("res://addons/blendot/launcher.gd")

var _launcher: Node
var _converter: RefCounted


func _init(launcher: Node, converter: RefCounted) -> void:
	_launcher = launcher
	_converter = converter


func _popup_menu(paths: PackedStringArray) -> void:
	if paths.size() != 1:
		return
	var path := paths[0]
	var ext := path.get_extension().to_lower()
	if ext not in SUPPORTED:
		return
	var theme := EditorInterface.get_editor_theme()
	var convertible: bool = _converter.can_convert(path)
	add_context_menu_item("Edit in Blender", _on_edit, theme.get_icon("Edit", "EditorIcons"))
	# In convert mode "Edit in Blender" already converts, so no separate item.
	if convertible and Launcher.mode() == Launcher.MODE_SIDECAR:
		add_context_menu_item("Convert to .blend...", _on_convert,
			theme.get_icon("Reload", "EditorIcons"))


func _on_edit(paths: PackedStringArray) -> void:
	var path := paths[0]
	if path.get_extension().to_lower() == "blend":
		_launcher.open_blend(path)
	elif _converter.can_convert(path) and Launcher.mode() == Launcher.MODE_CONVERT:
		_converter.confirm_and_convert(path, true)
	else:
		_launcher.edit_file(path)


func _on_convert(paths: PackedStringArray) -> void:
	_converter.confirm_and_convert(paths[0], false)
