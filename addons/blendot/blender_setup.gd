@tool
extends RefCounted
## Finds, tests and remembers the Blender executable. The path lives in Godot's
## own Blender importer setting, so .blend import and Blendot share one answer.

const SETTING := "filesystem/import/blender/blender_path"
const OLD_SETTING := "blendot/blender_path"
const MIN_VERSION := [4, 2]
const FLATPAK_PERMISSION := "flatpak override --user --talk-name=org.freedesktop.Flatpak "

## The path that last passed probe() this session, so each launch doesn't re-test.
static var _verified := ""
static var _menu_icon: Texture2D


## The logo at menu-icon size (16 px times the editor scale). Loaded lazily, not
## preloaded, so the plugin still compiles before Godot has imported the PNG.
static func menu_icon() -> Texture2D:
	if _menu_icon == null:
		var tex: Texture2D = load("res://addons/blendot/icons/blendot_menu.png")
		if tex == null:
			return EditorInterface.get_editor_theme().get_icon("Edit", "EditorIcons")
		var image := tex.get_image()
		var size := int(16 * EditorInterface.get_editor_scale())
		image.resize(size, size, Image.INTERPOLATE_LANCZOS)
		_menu_icon = ImageTexture.create_from_image(image)
	return _menu_icon


static func in_flatpak() -> bool:
	return OS.has_environment("FLATPAK_ID")


## Moves a path set in Blendot's old setting into Godot's, then drops the old one.
static func migrate_old_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(OLD_SETTING):
		return
	var old := str(es.get_setting(OLD_SETTING))
	if old != "" and configured_path() == "":
		es.set_setting(SETTING, old)
	es.erase(OLD_SETTING)


static func configured_path() -> String:
	var es := EditorInterface.get_editor_settings()
	return str(es.get_setting(SETTING)) if es.has_setting(SETTING) else ""


## Turns a macOS Blender.app into the executable inside it.
static func resolve(path: String) -> String:
	path = path.strip_edges().trim_suffix("/")
	if path.ends_with(".app"):
		return path.path_join("Contents/MacOS/Blender")
	return path if path != "" else "blender"


## The argv that starts Blender. Inside a Flatpak Godot, Blender runs on the host.
static func command(path := configured_path()) -> PackedStringArray:
	if in_flatpak():
		return PackedStringArray(["flatpak-spawn", "--host", resolve(path)])
	return PackedStringArray([resolve(path)])


## Runs Blender to completion; returns its exit code (see OS.execute).
static func execute(args: PackedStringArray, output: Array = [], path := configured_path()) -> int:
	var cmd := command(path)
	return OS.execute(cmd[0], cmd.slice(1) + args, output, true)


## Starts Blender without waiting; returns the pid, or -1.
static func spawn(args: PackedStringArray) -> int:
	var cmd := command()
	return OS.create_process(cmd[0], cmd.slice(1) + args)


## Runs `blender --version`. Returns {"ok": bool, "message": String}.
static func probe(path: String) -> Dictionary:
	var output := []
	var code := execute(PackedStringArray(["--version"]), output, path)
	var text := "\n".join(output).strip_edges()
	for line in text.split("\n"):
		line = line.strip_edges()
		if not line.begins_with("Blender "):
			continue
		var nums := line.trim_prefix("Blender ").split(" ")[0].split(".")
		var major := int(nums[0])
		var minor := int(nums[1]) if nums.size() > 1 else 0
		if major < MIN_VERSION[0] or (major == MIN_VERSION[0] and minor < MIN_VERSION[1]):
			return {"ok": false, "message": "%s found, but Blendot needs Blender %d.%d or newer." \
				% [line, MIN_VERSION[0], MIN_VERSION[1]]}
		return {"ok": true, "message": line}
	var message := "Could not run %s." % resolve(path)
	if in_flatpak():
		message += "\nGodot is a Flatpak: check it may start programs on the host (see below)."
	if text:
		message += "\n" + text.right(400)
	return {"ok": false, "message": message}


## True if Blender is usable. If not, opens the Connect dialog and returns false,
## so the caller can simply stop; the user retries once Blender is connected.
static func ensure() -> bool:
	var path := configured_path()
	if path != "" and path == _verified:
		return true
	if probe(path).ok:
		_verified = path
		return true
	show_dialog("Blendot needs Blender to do that, but couldn't start it.")
	return false


## Blender executables in the usual places for this OS, newest-looking last.
static func candidates() -> PackedStringArray:
	var found := PackedStringArray()
	match OS.get_name():
		"Windows":
			for root in [OS.get_environment("ProgramFiles"), OS.get_environment("ProgramFiles(x86)")]:
				if root == "":
					continue
				var base: String = root.path_join("Blender Foundation")
				for sub in DirAccess.get_directories_at(base):
					var exe := base.path_join(sub).path_join("blender.exe")
					if FileAccess.file_exists(exe):
						found.append(exe)
		"macOS":
			for root in ["/Applications", OS.get_environment("HOME").path_join("Applications")]:
				for sub in DirAccess.get_directories_at(root):
					if sub.begins_with("Blender") and sub.ends_with(".app"):
						found.append(root.path_join(sub))
		_:
			# Asked of the host shell, so it also works from inside a Flatpak Godot.
			var script := ('for p in "$(command -v blender)" /usr/bin/blender /usr/local/bin/blender'
				+ ' /snap/bin/blender /opt/blender*/blender "$HOME"/blender*/blender'
				+ ' "$HOME"/Applications/blender*/blender'
				+ ' "$HOME"/.local/share/flatpak/exports/bin/org.blender.Blender'
				+ ' /var/lib/flatpak/exports/bin/org.blender.Blender;'
				+ ' do [ -f "$p" ] && [ -x "$p" ] && echo "$p"; done')
			# Run from a file: OS.execute re-quotes arguments, which mangles "$(...)".
			var file := OS.get_cache_dir().path_join("blendot_find_blender.sh")
			var f := FileAccess.open(file, FileAccess.WRITE)
			f.store_string(script + "\n")
			f.close()
			var output := []
			if in_flatpak():
				OS.execute("flatpak-spawn", ["--host", "sh", file], output)
			else:
				OS.execute("sh", [file], output)
			DirAccess.remove_absolute(file)
			for line in "\n".join(output).split("\n", false):
				if line not in found:
					found.append(line)
	return found


static func show_dialog(reason := "") -> void:
	var scale := EditorInterface.get_editor_scale()
	var dialog := ConfirmationDialog.new()
	dialog.title = "Blendot: Connect Blender"
	dialog.ok_button_text = "Use This Blender"
	dialog.min_size = Vector2i(620 * scale, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(8 * scale))
	dialog.add_child(box)

	var logo := TextureRect.new()
	logo.texture = load("res://addons/blendot/icons/blendot_logo.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(0, 64 * scale)
	box.add_child(logo)

	var intro := Label.new()
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.text = ((reason + "\n\n") if reason else "") + ("Choose the Blender to use. "
		+ "This is Godot's own Blender Path (Editor Settings → FileSystem → Import → Blender), "
		+ "so .blend import uses it too.")
	box.add_child(intro)

	var found := OptionButton.new()
	box.add_child(found)

	var row := HBoxContainer.new()
	box.add_child(row)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.placeholder_text = "Path to Blender"
	path_edit.text = configured_path()
	row.add_child(path_edit)
	var browse := Button.new()
	browse.text = "Browse…"
	row.add_child(browse)
	var test := Button.new()
	test.text = "Test"
	row.add_child(test)

	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status)

	if in_flatpak():
		var note := Label.new()
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.text = ("Godot is running as a Flatpak, so Blendot starts Blender on the host. "
			+ "If testing fails, run this once in a terminal, then restart Godot:")
		box.add_child(note)
		var cmd := LineEdit.new()
		cmd.editable = false
		cmd.text = FLATPAK_PERMISSION + OS.get_environment("FLATPAK_ID")
		box.add_child(cmd)

	var file_dialog := EditorFileDialog.new()
	file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_ANY  # a macOS .app is a folder
	file_dialog.title = "Choose the Blender executable"
	dialog.add_child(file_dialog)

	var ok := dialog.get_ok_button()
	var run_test := func() -> void:
		var result := probe(path_edit.text)
		status.text = ("✓ " if result.ok else "✗ ") + result.message
		status.add_theme_color_override("font_color",
			box.get_theme_color("success_color" if result.ok else "error_color", "Editor"))
		ok.disabled = not result.ok
	var pick := func(path: String) -> void:
		path_edit.text = path
		run_test.call()
	var detect := func() -> void:
		found.clear()
		var paths := candidates()
		found.add_item("Found %d Blender install%s" % [paths.size(), "" if paths.size() == 1 else "s"]
			if paths else "No Blender found in the usual places — browse to it")
		found.set_item_disabled(0, true)
		for p in paths:
			found.add_item(p)
		found.select(0)

	found.item_selected.connect(func(i): pick.call(found.get_item_text(i)))
	browse.pressed.connect(func(): file_dialog.popup_file_dialog())
	file_dialog.file_selected.connect(pick)
	file_dialog.dir_selected.connect(pick)
	test.pressed.connect(run_test)
	path_edit.text_submitted.connect(func(_t): run_test.call())
	path_edit.text_changed.connect(func(_t):
		ok.disabled = true
		status.text = "Press Test to check this path.")
	dialog.confirmed.connect(func():
		EditorInterface.get_editor_settings().set_setting(SETTING, path_edit.text.strip_edges())
		_verified = path_edit.text.strip_edges()
		EditorInterface.get_editor_toaster().push_toast("Blendot: Blender connected.",
			EditorToaster.SEVERITY_INFO))
	dialog.visibility_changed.connect(func():
		if not dialog.visible: dialog.queue_free())

	EditorInterface.popup_dialog_centered(dialog)
	detect.call()
	if path_edit.text != "" or found.item_count == 1:
		run_test.call()
	else:
		pick.call(found.get_item_text(found.item_count - 1))
		found.select(found.item_count - 1)
