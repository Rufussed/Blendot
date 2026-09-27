"""Blendot bridge, passed to Blender by Godot:

    blender --python blendot_bridge.py -- --target <asset> --blend <file.blend>

Opens (or creates from the asset) the sidecar .blend. While this Blender session
runs, every save of that exact .blend exports back to the asset. Nothing is
stored in the .blend: opened any other way it's a plain file, and "Save As"
elsewhere never exports.
"""

import hashlib
import json
import os
import re
import sys
import uuid

import bpy
from bpy.app.handlers import persistent

# The one .blend -> asset pair this Blender session exports for. "node" mode
# edits a Godot MeshInstance3D: objects carry IDs so Godot can follow them.
_session = {"blend": None, "target": None, "mode": "file"}

PROP_ID = "blendot_id"
PROP_MAIN = "blendot_main"

# Set for the initial save right after importing, which must not export.
_skip_next_export = False


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _write_record(blend_path, target_abs):
    with open(blend_path + ".json", "w") as f:
        json.dump({"target": target_abs, "target_sha256": _sha256(target_abs)}, f, indent=2)


def _format_for(path):
    return os.path.splitext(path)[1].lower().lstrip(".")


# Blender's FBX importer names actions "<object>|<take>[|<layer>]"; strip that
# back to the take name so animation names survive round trips unchanged.
_GENERIC_LAYER = re.compile(r"\|(Base ?Layer|Layer ?\d*|AnimLayer\d*)$", re.IGNORECASE)


def _restore_take_names():
    for action in bpy.data.actions:
        name = action.name
        for user in [o for o in bpy.data.objects if o.animation_data]:
            if user.animation_data.action == action and name.startswith(user.name + "|"):
                name = name[len(user.name) + 1:]
                break
        else:
            name = name.split("|", 1)[1] if "|" in name else name
        action.name = _GENERIC_LAYER.sub("", name)


# FBX material property (lowercase, without a "Maya|"-style prefix) ->
# (Principled BSDF input, is colour data). Blender's importer only knows the
# classic names, so textures on e.g. Arnold/Maya materials arrive unconnected.
_TEXTURE_INPUTS = {
    "basecolor": ("Base Color", True),
    "diffusecolor": ("Base Color", True),
    "diffuseroughness": ("Roughness", False),
    "specularroughness": ("Roughness", False),
    "roughness": ("Roughness", False),
    "metalness": ("Metallic", False),
    "metallic": ("Metallic", False),
    "emissioncolor": ("Emission Color", True),
    "emissivecolor": ("Emission Color", True),
    "opacity": ("Alpha", False),
    "transparencyfactor": ("Alpha", False),
    "normalcamera": ("Normal", False),
    "normalmap": ("Normal", False),
}


def _fbx_texture_links(path):
    """(material name, image name, texture name, property) per texture->material link."""
    from io_scene_fbx import parse_fbx
    root, _version = parse_fbx.parse(path)
    objects, links, videos = {}, [], {}
    for elem in root.elems:
        if elem.id == b"Objects":
            for o in elem.elems:
                objects[o.props[0]] = (o.id, o.props[1].split(b"\x00")[0].decode("utf-8", "replace"))
    for elem in root.elems:
        if elem.id != b"Connections":
            continue
        for c in elem.elems:
            src, dst = objects.get(c.props[1]), objects.get(c.props[2])
            if not src or not dst:
                continue
            if c.props[0] == b"OO" and src[0] == b"Video" and dst[0] == b"Texture":
                videos[dst[1]] = src[1]
            elif c.props[0] == b"OP" and src[0] == b"Texture" and dst[0] == b"Material":
                links.append((dst[1], src[1], c.props[3].decode("utf-8", "replace")))
    return [(mat, videos.get(tex, tex), tex, prop) for mat, tex, prop in links]


def _link_missing_fbx_textures(path):
    try:
        links = _fbx_texture_links(path)
    except Exception as err:  # never block editing over texture wiring
        print(f"Blendot: could not read FBX texture links: {err}")
        return
    for mat_name, video, tex, prop in links:
        target = _TEXTURE_INPUTS.get(prop.rsplit("|", 1)[-1].lower())
        mat = bpy.data.materials.get(mat_name)
        img = bpy.data.images.get(video) or bpy.data.images.get(tex)
        if not target or not mat or not img or not mat.use_nodes:
            continue
        nodes, node_links = mat.node_tree.nodes, mat.node_tree.links
        bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
        socket = bsdf.inputs.get(target[0]) if bsdf else None
        if socket is None or socket.is_linked:
            continue  # Blender already wired it (or another texture did)
        image_node = nodes.new("ShaderNodeTexImage")
        image_node.image = img
        image_node.location = (bsdf.location.x - 600, bsdf.location.y - 300 * list(bsdf.inputs).index(socket) / 10)
        if not target[1]:
            img.colorspace_settings.name = "Non-Color"
        if target[0] == "Normal":
            normal_map = next((n for n in nodes if n.type == "NORMAL_MAP"), None) \
                or nodes.new("ShaderNodeNormalMap")
            node_links.new(image_node.outputs["Color"], normal_map.inputs["Color"])
            node_links.new(normal_map.outputs["Normal"], socket)
        elif target[0] == "Alpha":
            node_links.new(image_node.outputs["Alpha"], socket)
        else:
            node_links.new(image_node.outputs["Color"], socket)
        print(f"Blendot: linked texture {img.name} -> {mat.name}.{target[0]} (from {prop})")


def import_asset(path):
    fmt = _format_for(path)
    if fmt == "fbx":
        bpy.ops.import_scene.fbx(filepath=path)
        _restore_take_names()
        _link_missing_fbx_textures(path)
    elif fmt in ("glb", "gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif fmt == "obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise ValueError(f"Blendot: unsupported format '{fmt}'")


def export_asset(path, fmt):
    if fmt == "fbx":
        _export_fbx(path)
    elif fmt == "glb":
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                                  export_extras=True, export_apply=True)
    elif fmt == "gltf":
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE")
    elif fmt == "obj":
        bpy.ops.wm.obj_export(filepath=path, export_selected_objects=False)
    else:
        raise ValueError(f"Blendot: unsupported format '{fmt}'")


def _export_fbx(path):
    from io_scene_fbx import export_fbx_bin

    # The exporter names each take "<object>|<action>"; use the action name alone
    # so a take called "Run" comes back to Godot as "Run", not "Armature|Run".
    original = export_fbx_bin.get_blenderID_name

    def take_name(bid):
        if isinstance(bid, tuple) and len(bid) == 2 and isinstance(bid[1], bpy.types.Action):
            return bid[1].name
        return original(bid)

    export_fbx_bin.get_blenderID_name = take_name
    try:
        bpy.ops.export_scene.fbx(filepath=path, use_selection=False,
                                 apply_scale_options="FBX_SCALE_ALL",
                                 add_leaf_bones=False,
                                 path_mode="COPY", embed_textures=True)
    finally:
        export_fbx_bin.get_blenderID_name = original


def _is_session_file():
    blend = _session["blend"]
    return blend and os.path.normpath(bpy.data.filepath) == blend


def _assign_ids():
    """Give every object a stable ID (copied objects get fresh ones)."""
    seen = set()
    for obj in sorted(bpy.data.objects, key=lambda o: o.name):
        oid = obj.get(PROP_ID)
        if not oid or oid in seen:
            oid = obj[PROP_ID] = uuid.uuid4().hex[:12]
        seen.add(oid)
    # .blend files from before main-object marking: adopt the first mesh.
    if not any(o.get(PROP_MAIN) for o in bpy.data.objects):
        meshes = [o for o in bpy.data.objects if o.type == "MESH"]
        if meshes:
            meshes[0][PROP_MAIN] = True


@persistent
def _on_save_pre(*_args):
    if _is_session_file() and _session["mode"] == "node":
        _assign_ids()


@persistent
def _on_save_post(*_args):
    global _skip_next_export
    blend, target = _session["blend"], _session["target"]
    if not _is_session_file():
        return
    if _skip_next_export:
        _skip_next_export = False
        return
    export_asset(target, _format_for(target))
    _write_record(blend, target)
    print(f"Blendot: exported {target}")


def start_session(target, blend, mode="file"):
    _session["blend"] = os.path.normpath(blend)
    _session["target"] = os.path.normpath(target)
    _session["mode"] = mode
    if _on_save_pre not in bpy.app.handlers.save_pre:
        bpy.app.handlers.save_pre.append(_on_save_pre)
    if _on_save_post not in bpy.app.handlers.save_post:
        bpy.app.handlers.save_post.append(_on_save_post)


def _parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return {key.lstrip("-"): value for key, value in zip(argv[::2], argv[1::2])}


def _set_material_preview():
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                for space in area.spaces:
                    if space.type == "VIEW_3D":
                        space.shading.type = "MATERIAL"


def _open_or_create(target, blend):
    global _skip_next_export
    if os.path.exists(blend):
        bpy.ops.wm.open_mainfile(filepath=blend)
        _set_material_preview()
        return None

    bpy.ops.wm.read_homefile(use_empty=True)
    import_asset(target)
    if _session["mode"] == "node":
        # Godot exported exactly one object: the node's own mesh.
        meshes = [o for o in bpy.data.objects if o.type == "MESH"]
        if meshes:
            meshes[0][PROP_MAIN] = True
    _set_material_preview()
    _skip_next_export = True  # don't re-export an unedited import
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    _write_record(blend, target)
    return None  # stop the timer


def convert(target, blend):
    """Import target into a new .blend that replaces it (run with blender -b)."""
    bpy.ops.wm.read_homefile(use_empty=True)
    import_asset(target)
    _set_material_preview()
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    print(f"Blendot: converted {target} -> {blend}")


def _open_plain(blend):
    bpy.ops.wm.open_mainfile(filepath=blend)
    _set_material_preview()
    return None


if __name__ == "__main__":
    opts = _parse_args()
    mode = opts.get("mode", "file")
    if mode == "convert":
        convert(opts["target"], opts["blend"])
    elif mode == "plain":
        # A .blend Godot imports directly: nothing to export, Godot reimports it.
        bpy.app.timers.register(lambda: _open_plain(opts["blend"]), first_interval=0.1)
    elif "target" in opts and "blend" in opts:
        start_session(opts["target"], opts["blend"], mode)
        # Defer until Blender's UI is ready so operators have a valid context.
        bpy.app.timers.register(
            lambda: _open_or_create(opts["target"], opts["blend"]), first_interval=0.1)
