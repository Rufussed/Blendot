@tool
extends RefCounted
## Edits a MeshInstance3D in Blender. The node's mesh is exported as the "main"
## object, with Blender's world origin as the node's origin. On each Blender save:
##   * the main object's mesh (with its offset baked in) becomes the node's mesh;
##   * every other object becomes a descendant node, keeping Blender's hierarchy,
##     with its own origin and a transform relative to its parent.
## Blender objects carry stable IDs (glTF extras), so renames and reparenting
## update the same Godot node, keeping scripts etc. that were added in Godot.

const SETTING_MESH_DIR := "blendot/mesh_dir"
const META_ID := "blendot_id"
const META_EDIT_ID := "blendot_edit_id"
const RETRY_LIMIT := 5

var _launcher: Node
## glb abs path -> {"node": WeakRef, "retries": int}
var _sessions := {}


func _init(launcher: Node) -> void:
	_launcher = launcher


static func register_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_MESH_DIR):
		ProjectSettings.set_setting(SETTING_MESH_DIR, "res://blendot_meshes")
	ProjectSettings.set_initial_value(SETTING_MESH_DIR, "res://blendot_meshes")
	ProjectSettings.set_as_basic(SETTING_MESH_DIR, true)
	ProjectSettings.add_property_info({"name": SETTING_MESH_DIR, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR})


func edit(node: MeshInstance3D) -> void:
	if node.mesh == null:
		push_warning("Blendot: %s has no mesh to edit." % node.name)
		return
	var glb := _glb_path(node)
	var glb_abs := ProjectSettings.globalize_path(glb)
	var blend_abs := glb_abs + ".blend"
	DirAccess.make_dir_recursive_absolute(glb_abs.get_base_dir())

	# An existing .blend is the source of truth; only export for a fresh one.
	if not FileAccess.file_exists(blend_abs):
		var err := _export_glb(node, glb_abs)
		if err != OK:
			push_error("Blendot: exporting %s to glTF failed (%s)." % [node.name, error_string(err)])
			return

	_sessions[glb_abs] = {"node": weakref(node), "retries": 0}
	_launcher.launch(glb_abs, blend_abs, false, _on_glb_changed, "node")


## Per node, keyed by an ID stored on the node (saved with the scene), so a new
## node never picks up a deleted one's .blend just because it has the same name.
func _glb_path(node: MeshInstance3D) -> String:
	var id := _edit_id(node)
	var dir: String = ProjectSettings.get_setting(_launcher.SETTING_SIDECAR_DIR, "res://.blendot")
	return dir.path_join("nodes").path_join(("%s_%s" % [node.name, id]).validate_filename() + ".glb")


func _edit_id(node: MeshInstance3D) -> String:
	var id: String = node.get_meta(META_EDIT_ID, "")
	var root := EditorInterface.get_edited_scene_root()
	var taken := false
	if id and root:
		# Ctrl+D copies metadata: a duplicate must not share the original's .blend.
		for other in [root] + root.find_children("*", "", true, false):
			if other != node and other.get_meta(META_EDIT_ID, "") == id:
				taken = true
				break
	if id == "" or taken:
		id = "%08x%04x" % [randi(), Time.get_ticks_usec() & 0xffff]
		node.set_meta(META_EDIT_ID, id)
		EditorInterface.mark_scene_as_unsaved()
	return id


# --- export ----------------------------------------------------------------------

func _export_glb(node: MeshInstance3D, path: String) -> Error:
	# The node itself is the glTF root at identity: Blender edits in its local space.
	var instance := MeshInstance3D.new()
	instance.name = node.name
	instance.mesh = _export_mesh(node.mesh, node.name)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(instance, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	instance.free()
	return err


## A copy for export: always an ArrayMesh (glTF export skips PrimitiveMeshes),
## with every material named so it can be matched back to Godot's on import.
func _export_mesh(mesh: Mesh, node_name: String) -> ArrayMesh:
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var primitive := Mesh.PRIMITIVE_TRIANGLES
		if mesh is ArrayMesh:
			primitive = mesh.surface_get_primitive_type(i)
		out.add_surface_from_arrays(primitive, mesh.surface_get_arrays(i))
		var mat := mesh.surface_get_material(i)
		if mat == null and mesh is PrimitiveMesh:
			mat = mesh.material
		if mat:
			if _material_name(mat) == "":
				mat.resource_name = "%s_%d" % [node_name, i]
			var named := mat.duplicate()
			named.resource_name = _material_name(mat)
			mat = named
		out.surface_set_material(i, mat)
	return out


static func _material_name(mat: Material) -> String:
	if mat.resource_name:
		return mat.resource_name
	if mat.resource_path and not mat.resource_path.contains("::"):
		return mat.resource_path.get_file().get_basename()
	return ""


# --- import ----------------------------------------------------------------------

func _on_glb_changed(glb_abs: String) -> void:
	var session: Dictionary = _sessions.get(glb_abs, {})
	if session.is_empty():
		return
	var node := session.node.get_ref() as MeshInstance3D
	if node == null or not node.is_inside_tree():
		push_warning("Blendot: the node for %s is gone; Blender changes not applied."
			% glb_abs.get_file())
		return

	var parsed := _parse_glb(glb_abs)
	if parsed.is_empty():
		# Blender may still be writing the file; try again shortly.
		session.retries += 1
		if session.retries <= RETRY_LIMIT:
			_launcher.get_tree().create_timer(0.5).timeout.connect(
				_on_glb_changed.bind(glb_abs))
		else:
			push_error("Blendot: could not read %s." % glb_abs)
		return
	session.retries = 0
	_apply(node, parsed, glb_abs)


## Returns {"main_mesh": ArrayMesh or null, "entries": [...]}, entries in
## parent-before-child order: {id, name, parent_id ("" = the edited node),
## transform, mesh (ArrayMesh or null for an empty)}. Empty dict if unreadable.
func _parse_glb(glb_abs: String) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb_abs, state) != OK:
		return {}
	var scene := doc.generate_scene(state)
	if scene == null:
		return {}

	var main: Node3D = null
	for n in scene.find_children("*", "", true, false):
		if _extras(n).get("blendot_main", false):
			main = n
			break
	if main == null:  # no marker: fall back to the first mesh
		for n in scene.find_children("*", "", true, false):
			if _mesh_of(n):
				main = n
				break

	var result := {"main_mesh": null, "entries": []}
	if main:
		var main_xform := _to_root(main, scene)
		result.main_mesh = _baked(_mesh_of(main), main_xform)
		for child in main.get_children():
			_collect(child, "", main_xform, result.entries)
	for child in scene.get_children():
		if child != main:
			_collect(child, "", Transform3D.IDENTITY, result.entries)
	scene.free()
	return result


func _collect(n: Node, parent_id: String, prefix: Transform3D, entries: Array) -> void:
	if not (n is Node3D) or n is Camera3D or n is Light3D:
		return
	var id: String = _extras(n).get("blendot_id", "name:" + n.name)
	entries.append({"id": id, "name": String(n.name), "parent_id": parent_id,
		"transform": prefix * n.transform, "mesh": _mesh_of(n)})
	for child in n.get_children():
		_collect(child, id, Transform3D.IDENTITY, entries)


static func _to_root(n: Node3D, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	while n and n != root:
		xform = n.transform * xform
		n = n.get_parent() as Node3D
	return xform


static func _extras(n: Node) -> Dictionary:
	var extras = n.get_meta("extras", {})
	return extras if extras is Dictionary else {}


## In the editor glTF generates ImporterMeshInstance3D; at runtime, MeshInstance3D.
static func _mesh_of(n: Node) -> ArrayMesh:
	if n is ImporterMeshInstance3D:
		return n.mesh.get_mesh() if n.mesh else null
	if n is MeshInstance3D:
		return n.mesh as ArrayMesh
	return null


## The mesh with xform baked into its vertices (moving the main object in
## Blender moves its geometry relative to the node's origin).
static func _baked(mesh: ArrayMesh, xform: Transform3D) -> ArrayMesh:
	if mesh == null or xform.is_equal_approx(Transform3D.IDENTITY):
		return mesh
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var st := SurfaceTool.new()
		st.append_from(mesh, i, xform)
		st.commit(out)
		out.surface_set_material(i, mesh.surface_get_material(i))
		out.surface_set_name(i, mesh.surface_get_name(i))
	return out


# --- apply -----------------------------------------------------------------------

func _apply(node: MeshInstance3D, parsed: Dictionary, glb_abs: String) -> void:
	var owner := node.owner if node.owner else node
	var existing := _existing_by_id(node)
	var materials := _godot_materials(node, existing.values())
	var dir: String = ProjectSettings.get_setting(SETTING_MESH_DIR, "res://blendot_meshes")
	var base := dir.path_join(glb_abs.get_file().get_basename())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var saved: Array[String] = []

	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Blendot: update %s from Blender" % node.name, UndoRedo.MERGE_DISABLE, owner, true)

	var main_mesh: ArrayMesh = parsed.main_mesh
	if main_mesh:
		main_mesh = _persist(main_mesh, base + ".res", materials, saved)
		undo.add_do_property(node, "mesh", main_mesh)
		undo.add_undo_property(node, "mesh", node.mesh)
	else:
		push_warning("Blendot: no main object found in Blender; %s's own mesh unchanged." % node.name)

	var resolved := {"": node}  # blender id -> Godot node, once placed
	var kept := {}
	for e in parsed.entries:
		var parent: Node = resolved.get(e.parent_id, node)
		var mesh: ArrayMesh = null
		if e.mesh:
			mesh = _persist(e.mesh, "%s_%s.res" % [base, e.id.validate_filename()], materials, saved)
		var target: Node3D = existing.get(e.id)
		if target and (target is MeshInstance3D) != (mesh != null):
			target = null  # became/stopped being a mesh: replace the node
		if target == null:
			target = MeshInstance3D.new() if mesh else Node3D.new()
			target.set_meta(META_ID, e.id)
			undo.add_do_method(self, "_attach", target, parent, -1, [target], owner)
			undo.add_do_reference(target)
			undo.add_undo_method(self, "_detach", target)
		else:
			kept[e.id] = true
			if target.get_parent() != parent:
				var old_parent := target.get_parent()
				var owned := _owned_subtree(target, owner)
				undo.add_do_method(self, "_detach", target)
				undo.add_do_method(self, "_attach", target, parent, -1, owned, owner)
				# Undo ops run in reverse (backward_undo_ops), so: detach, then re-attach.
				undo.add_undo_method(self, "_attach", target, old_parent, target.get_index(), owned, owner)
				undo.add_undo_method(self, "_detach", target)
		_record(undo, target, "name", StringName(e.name))
		_record(undo, target, "transform", e.transform)
		if mesh:
			_record(undo, target, "mesh", mesh)
		resolved[e.id] = target

	# Objects deleted in Blender: remove the nodes Blendot made for them (and
	# only those; nodes added in Godot are never touched unless inside one).
	for id in existing:
		var gone: Node = existing[id]
		if kept.has(id) or (gone.get_parent() and gone.get_parent().has_meta(META_ID)
				and not kept.has(gone.get_parent().get_meta(META_ID))):
			continue
		undo.add_do_method(self, "_detach", gone)
		undo.add_undo_method(self, "_attach", gone, gone.get_parent(), gone.get_index(),
			_owned_subtree(gone, owner), owner)
		undo.add_undo_reference(gone)

	undo.commit_action()
	for path in saved:
		EditorInterface.get_resource_filesystem().update_file(path)
	print("Blendot: updated %s from Blender (%d child objects)" % [node.name, parsed.entries.size()])


func _record(undo: EditorUndoRedoManager, obj: Object, prop: String, value: Variant) -> void:
	undo.add_do_property(obj, prop, value)
	undo.add_undo_property(obj, prop, obj.get(prop))


func _attach(n: Node, parent: Node, index: int, owned: Array, owner: Node) -> void:
	parent.add_child(n)
	if index >= 0:
		parent.move_child(n, mini(index, parent.get_child_count() - 1))
	for o in owned:
		o.owner = owner


func _detach(n: Node) -> void:
	if n.get_parent():
		n.get_parent().remove_child(n)


static func _owned_subtree(n: Node, owner: Node) -> Array:
	var out := [n]
	for d in n.find_children("*", "", true, false):
		if d.owner == owner:
			out.append(d)
	return out


## Nodes Blendot created under node, by Blender object ID.
static func _existing_by_id(node: Node) -> Dictionary:
	var out := {}
	for d in node.find_children("*", "", true, false):
		if d.has_meta(META_ID):
			out[d.get_meta(META_ID)] = d
	return out


## Godot materials currently used, by name, so Blender round trips keep them.
static func _godot_materials(node: MeshInstance3D, others: Array) -> Dictionary:
	var out := {}
	for n in [node] + others:
		var mesh: Mesh = n.get("mesh")
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i)
			if mat and _material_name(mat):
				out[_material_name(mat)] = mat
	return out


## Swaps in Godot's own material wherever Blender's has the same name, then
## saves the mesh as a .res so the edit survives reloading the scene.
func _persist(mesh: ArrayMesh, path: String, materials: Dictionary, saved: Array[String]) -> ArrayMesh:
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i)
		if mat and materials.has(mat.resource_name):
			mesh.surface_set_material(i, materials[mat.resource_name])
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		push_error("Blendot: saving %s failed (%s)." % [path, error_string(err)])
		return mesh
	mesh.take_over_path(path)
	saved.append(path)
	return mesh
