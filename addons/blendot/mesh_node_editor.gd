@tool
extends RefCounted
## Edits a MeshInstance3D's mesh in Blender: exports it to a sidecar .glb,
## and when Blender rewrites that .glb, swaps the new mesh into the node.

const SETTING_MESH_DIR := "blendot/mesh_dir"
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
		var err := _export_glb(node.mesh, glb_abs)
		if err != OK:
			push_error("Blendot: exporting %s to glTF failed (%s)." % [node.name, error_string(err)])
			return

	_sessions[glb_abs] = {"node": weakref(node), "retries": 0}
	_launcher.launch(glb_abs, blend_abs, false, _on_glb_changed)


## Stable per node: scene file + node path, so re-editing reopens the same .blend.
func _glb_path(node: MeshInstance3D) -> String:
	var root := EditorInterface.get_edited_scene_root()
	var scene_file := root.scene_file_path if root.scene_file_path else "unsaved"
	var key := "%s::%s" % [scene_file, root.get_path_to(node)]
	var name := "%s_%s_%s" % [scene_file.get_file().get_basename(), node.name,
		key.md5_text().left(8)]
	var dir: String = ProjectSettings.get_setting(_launcher.SETTING_SIDECAR_DIR, "res://.blendot")
	return dir.path_join("nodes").path_join(name.validate_filename() + ".glb")


func _export_glb(mesh: Mesh, path: String) -> Error:
	# Identity transform: Blender edits the mesh in its local space.
	var root := Node3D.new()
	var instance := MeshInstance3D.new()
	instance.name = "Mesh"
	instance.mesh = _to_array_mesh(mesh)
	root.add_child(instance)
	instance.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err


## glTF export skips PrimitiveMeshes (BoxMesh, CylinderMesh...), so bake to ArrayMesh.
func _to_array_mesh(mesh: Mesh) -> ArrayMesh:
	if mesh is ArrayMesh:
		return mesh
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(i))
		var mat := mesh.surface_get_material(i)
		if mat == null and mesh is PrimitiveMesh:
			mat = mesh.material
		out.surface_set_material(i, mat)
	return out


func _on_glb_changed(glb_abs: String) -> void:
	var session: Dictionary = _sessions.get(glb_abs, {})
	if session.is_empty():
		return
	var node := session.node.get_ref() as MeshInstance3D
	if node == null or not node.is_inside_tree():
		push_warning("Blendot: the node for %s is gone; Blender changes not applied."
			% glb_abs.get_file())
		return

	var new_mesh := _load_mesh(glb_abs)
	if new_mesh == null:
		# Blender may still be writing the file; try again shortly.
		session.retries += 1
		if session.retries <= RETRY_LIMIT:
			_launcher.get_tree().create_timer(0.5).timeout.connect(
				_on_glb_changed.bind(glb_abs))
		else:
			push_error("Blendot: could not read %s." % glb_abs)
		return
	session.retries = 0
	_apply(node, new_mesh, glb_abs)


func _load_mesh(glb_abs: String) -> ArrayMesh:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb_abs, state) != OK:
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		return null
	# In the editor, glTF generates ImporterMeshInstance3D; at runtime, MeshInstance3D.
	var instances := [scene] + scene.find_children("*", "", true, false)
	instances = instances.filter(func(n): return n is MeshInstance3D or n is ImporterMeshInstance3D)
	var mesh: ArrayMesh = null
	if instances:
		var first: Node = instances[0]
		if first is ImporterMeshInstance3D:
			mesh = first.mesh.get_mesh() if first.mesh else null
		else:
			mesh = first.mesh as ArrayMesh
	if instances.size() > 1:
		push_warning("Blendot: %s has %d objects; using '%s'. Join them in Blender to keep all."
			% [glb_abs.get_file(), instances.size(), instances[0].name])
	scene.free()
	return mesh


func _apply(node: MeshInstance3D, new_mesh: ArrayMesh, glb_abs: String) -> void:
	var old_mesh := node.mesh
	# Keep Godot's own materials for surfaces that still exist; glTF round-trips
	# lose shader materials and Godot-only settings.
	for i in mini(old_mesh.get_surface_count(), new_mesh.get_surface_count()):
		var mat := old_mesh.surface_get_material(i)
		if mat:
			new_mesh.surface_set_material(i, mat)

	# Save as a .res so the edit survives reloading the scene.
	var dir: String = ProjectSettings.get_setting(SETTING_MESH_DIR, "res://blendot_meshes")
	var res_path := dir.path_join(glb_abs.get_file().get_basename() + ".res")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var err := ResourceSaver.save(new_mesh, res_path)
	if err != OK:
		push_error("Blendot: saving %s failed (%s)." % [res_path, error_string(err)])
		return
	new_mesh.take_over_path(res_path)

	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Blendot: update %s from Blender" % node.name)
	undo.add_do_property(node, "mesh", new_mesh)
	undo.add_undo_property(node, "mesh", old_mesh)
	undo.commit_action()
	EditorInterface.get_resource_filesystem().update_file(res_path)
	print("Blendot: updated %s from Blender -> %s" % [node.name, res_path])
