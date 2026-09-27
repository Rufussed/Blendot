@tool
extends RefCounted
## Finds what refers to a node that's about to be replaced (and maybe renamed):
##   * in the scene: exported Node / NodePath properties (also in arrays) and
##     AnimationPlayer track paths; these can be retargeted exactly, undoably;
##   * in scripts: $Name / "Name" text that may mean it; only listed, never edited.


## Changes needed in the scene so references follow `node` to `replacement`,
## which will sit at the same place named `new_name`. Returns
## {"props": [[object, property, old, new]], "tracks": [[animation, track, old, new]],
##  "readonly": [description]} for animations that live in other files.
static func scene_fixes(node: Node, replacement: Node, new_name: StringName) -> Dictionary:
	var fixes := {"props": [], "tracks": [], "readonly": []}
	var root: Node = node.owner if node.owner else node
	for other in [root] + root.find_children("*", "", true, false):
		if other == node or node.is_ancestor_of(other):
			continue  # the node's own subtree moves with it
		_property_fixes(other, node, replacement, new_name, fixes.props)
		if other is AnimationPlayer:
			_track_fixes(other, node, new_name, fixes)
	return fixes


static func _property_fixes(other: Node, node: Node, replacement: Node,
		new_name: StringName, out: Array) -> void:
	for prop in other.get_property_list():
		if not (prop.usage & PROPERTY_USAGE_STORAGE) or prop.name in ["owner", "script"]:
			continue
		var value = other.get(prop.name)
		var fixed = _fix_value(other, value, node, replacement, new_name)
		if fixed != null:
			out.append([other, prop.name, value, fixed])


## The value with references to node swapped, or null if nothing changes.
static func _fix_value(from: Node, value, node: Node, replacement: Node, new_name: StringName):
	if value is Node:
		return replacement if value == node else null
	if value is NodePath and not value.is_empty():
		var moved = retarget(from, value, node, new_name)
		return moved if moved != null and moved != value else null
	if value is Array:
		var changed := false
		var copy: Array = value.duplicate()
		for i in copy.size():
			var fixed = _fix_value(from, copy[i], node, replacement, new_name)
			if fixed != null:
				copy[i] = fixed
				changed = true
		return copy if changed else null
	return null


## `path` (as seen from `from`) rewritten to reach the same place once `node`
## is renamed new_name; null if it doesn't point at node or inside it.
static func retarget(from: Node, path: NodePath, node: Node, new_name: StringName):
	var names_only := NodePath(path.get_concatenated_names()) if path.get_name_count() else NodePath(".")
	var target := from.get_node_or_null(names_only)
	if target == null or not (target == node or node.is_ancestor_of(target)):
		return null
	var to_parent := str(from.get_path_to(node.get_parent()))
	var new_path := String(new_name) if to_parent == "." else to_parent + "/" + String(new_name)
	var inside := str(node.get_path_to(target))
	if inside != ".":
		new_path += "/" + inside
	var subnames := path.get_concatenated_subnames()
	return NodePath(new_path + (":" + subnames if subnames else ""))


static func _track_fixes(player: AnimationPlayer, node: Node, new_name: StringName, fixes: Dictionary) -> void:
	var base := player.get_node_or_null(player.root_node)
	if base == null:
		return
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			for i in anim.get_track_count():
				var old := anim.track_get_path(i)
				var moved = retarget(base, old, node, new_name)
				if moved == null or moved == old:
					continue
				if _is_local(anim) and _is_local(lib):
					fixes.tracks.append([anim, i, old, moved])
				else:
					fixes.readonly.append("animation \"%s\" (%s) track %s" % [anim_name,
						(anim.resource_path if not _is_local(anim) else lib.resource_path).get_file(), old])


## Saved inside the scene (so editing it here is saved with the scene).
static func _is_local(res: Resource) -> bool:
	return res.resource_path == "" or res.resource_path.contains("::")


## Script lines that may refer to a node called `name`: $name, %name, "name",
## "…/name" and "name/…". Text matches only, so they're listed, not edited.
static func script_mentions(name: String, limit := 12) -> PackedStringArray:
	var out := PackedStringArray()
	var escaped := _regex_escape(name)
	var pattern := RegEx.create_from_string(
		"([$%%]\"?%s\\b)|([\"'/]%s[\"'/:])" % [escaped, escaped])
	for path in _script_files("res://"):
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			if pattern.search(lines[i]):
				out.append("%s:%d  %s" % [path.trim_prefix("res://"), i + 1, lines[i].strip_edges().left(70)])
				if out.size() >= limit:
					out.append("...")
					return out
	return out


static func _regex_escape(text: String) -> String:
	var out := ""
	for ch in text:
		out += "\\" + ch if ch in ".^$*+?()[]{}|\\" else ch
	return out


static func _script_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		if f.get_extension() in ["gd", "cs"]:
			out.append(dir.path_join(f))
	for sub in da.get_directories():
		if not sub.begins_with(".") and dir.path_join(sub) != "res://addons":
			out.append_array(_script_files(dir.path_join(sub)))
	return out
