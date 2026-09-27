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
import sys

import bpy
from bpy.app.handlers import persistent

# The one .blend -> asset pair this Blender session exports for.
_session = {"blend": None, "target": None}

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


def import_asset(path):
    fmt = _format_for(path)
    if fmt == "fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif fmt in ("glb", "gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif fmt == "obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise ValueError(f"Blendot: unsupported format '{fmt}'")


def export_asset(path, fmt):
    if fmt == "fbx":
        bpy.ops.export_scene.fbx(filepath=path, use_selection=False,
                                 apply_scale_options="FBX_SCALE_ALL",
                                 add_leaf_bones=False)
    elif fmt == "glb":
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB")
    elif fmt == "gltf":
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE")
    elif fmt == "obj":
        bpy.ops.wm.obj_export(filepath=path, export_selected_objects=False)
    else:
        raise ValueError(f"Blendot: unsupported format '{fmt}'")


@persistent
def _on_save_post(*_args):
    global _skip_next_export
    blend, target = _session["blend"], _session["target"]
    if not blend or os.path.normpath(bpy.data.filepath) != blend:
        return
    if _skip_next_export:
        _skip_next_export = False
        return
    export_asset(target, _format_for(target))
    _write_record(blend, target)
    print(f"Blendot: exported {target}")


def start_session(target, blend):
    _session["blend"] = os.path.normpath(blend)
    _session["target"] = os.path.normpath(target)
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
    _set_material_preview()
    _skip_next_export = True  # don't re-export an unedited import
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    _write_record(blend, target)
    return None  # stop the timer


if __name__ == "__main__":
    opts = _parse_args()
    if "target" in opts and "blend" in opts:
        start_session(opts["target"], opts["blend"])
        # Defer until Blender's UI is ready so operators have a valid context.
        bpy.app.timers.register(
            lambda: _open_or_create(opts["target"], opts["blend"]), first_interval=0.1)
