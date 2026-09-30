extends Control
## Main scene for the Blendot repo: pick a Godot project and symlink the
## addon into it, so running this project does something useful.

var _status: Label
var _dialog: FileDialog


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var logo := TextureRect.new()
	logo.texture = preload("res://addons/blendot/icons/blendot_logo.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(0, 120)
	box.add_child(logo)

	var title := Label.new()
	title.text = "Blendot"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var button := Button.new()
	button.text = "Link Blendot into a project…"
	button.pressed.connect(func(): _dialog.popup_centered_ratio(0.7))
	box.add_child(button)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 480
	box.add_child(_status)

	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = true
	_dialog.title = "Choose a Godot project folder"
	_dialog.dir_selected.connect(_link_into)
	add_child(_dialog)


func _link_into(proj: String) -> void:
	var src := ProjectSettings.globalize_path("res://addons/blendot")
	var dest := proj.path_join("addons/blendot")

	if not FileAccess.file_exists(proj.path_join("project.godot")):
		_set_status("No project.godot in %s — pick the project's root folder." % proj, true)
		return
	if proj.simplify_path() == ProjectSettings.globalize_path("res://").simplify_path():
		_set_status("That's the Blendot repo itself.", true)
		return

	var dir := DirAccess.open(proj)
	if dir.is_link(dest):
		dir.remove(dest)
	elif dir.dir_exists(dest):
		_set_status("%s already exists as a real folder. Remove it first to use a link." % dest, true)
		return

	dir.make_dir_recursive("addons")
	var err := dir.create_link(src, dest)
	if err != OK:
		_set_status("Could not create link (%s)." % error_string(err), true)
		return
	_set_status("Linked into %s.\nEnable it in Project → Project Settings → Plugins." % proj.get_file(), false)


func _set_status(text: String, is_error: bool) -> void:
	_status.text = text
	_status.modulate = Color(1, 0.5, 0.5) if is_error else Color(0.6, 1, 0.6)
