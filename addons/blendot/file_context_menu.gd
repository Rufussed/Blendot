@tool
extends EditorContextMenuPlugin

const SUPPORTED := ["fbx", "glb", "gltf", "obj", "blend"]
const BlenderSession := preload("res://addons/blendot/blender_session.gd")
const BlenderSetup := preload("res://addons/blendot/blender_setup.gd")

var _session: Node
var _converter: RefCounted


func _init(session: Node, converter: RefCounted) -> void:
	_session = session
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
	add_context_menu_item("Edit in Blender", _on_edit, BlenderSetup.menu_icon())
	# In convert mode "Edit in Blender" already converts, so no separate item.
	if convertible and BlenderSession.mode() == BlenderSession.MODE_SIDECAR:
		add_context_menu_item("Convert to .blend...", _on_convert,
			theme.get_icon("Reload", "EditorIcons"))


func _on_edit(paths: PackedStringArray) -> void:
	edit_path(paths[0])


## What "Edit in Blender" does for a file, wherever it's triggered from.
func edit_path(path: String) -> void:
	if path.get_extension().to_lower() == "blend":
		_session.open_blend(path)
	elif _converter.can_convert(path) and BlenderSession.mode() == BlenderSession.MODE_CONVERT:
		_converter.confirm_and_convert(path, true)
	else:
		_session.edit_file(path)


func _on_convert(paths: PackedStringArray) -> void:
	_converter.confirm_and_convert(paths[0], false)
