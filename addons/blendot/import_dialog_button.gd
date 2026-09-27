@tool
extends RefCounted
## Adds "Edit in Blender" to the Advanced Import Settings dialog (double-click a
## model file). Godot has no API for this, so it finds the dialog by class; if a
## future Godot changes it, the button simply doesn't appear.

const ACTION := "blendot_edit_in_blender"

var _edit: Callable  # takes a res:// path
var _supported: Array
var _dialog: Window
var _button: Button
var _path := ""


func _init(edit: Callable, supported: Array) -> void:
	_edit = edit
	_supported = supported


func attach() -> void:
	var found := EditorInterface.get_base_control().find_children(
		"*", "SceneImportSettingsDialog", true, false)
	if found.is_empty() or not found[0] is AcceptDialog:
		return
	_dialog = found[0]
	_button = _dialog.add_button("Edit in Blender", false, ACTION)
	_button.icon = EditorInterface.get_editor_theme().get_icon("Edit", "EditorIcons")
	_button.hide()
	_dialog.visibility_changed.connect(_on_visibility_changed)
	_dialog.custom_action.connect(_on_custom_action)


func detach() -> void:
	if not is_instance_valid(_dialog):
		return
	_dialog.visibility_changed.disconnect(_on_visibility_changed)
	_dialog.custom_action.disconnect(_on_custom_action)
	if is_instance_valid(_button):
		_dialog.remove_button(_button)
		_button.queue_free()


func _on_visibility_changed() -> void:
	if not _dialog.visible:
		return
	# The dialog shows the file that was just double-clicked in the FileSystem dock.
	_path = EditorInterface.get_current_path()
	_button.visible = _path.get_extension().to_lower() in _supported


func _on_custom_action(action: StringName) -> void:
	if action != ACTION or _path == "":
		return
	_dialog.hide()
	_edit.call(_path)
