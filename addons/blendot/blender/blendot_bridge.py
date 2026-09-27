"""Blendot bridge: keeps a .blend as the editable source of a Godot asset and
exports to that asset on every save.

Used two ways:
  * launched by Godot: blender --python blendot_bridge.py -- --target <asset> --blend <file.blend>
  * installed as a Blender addon, so Blendot .blend files export even when
    opened directly in Blender.
"""

import hashlib
import json
import os
import sys

import bpy
from bpy.app.handlers import persistent

bl_info = {
    "name": "Blendot",
    "author": "Rufus Lane",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "category": "Import-Export",
    "description": "Export Blendot .blend files back to their Godot asset on save",
}

PROP_TARGET = "blendot_target"  # asset path, relative to the .blend
PROP_FORMAT = "blendot_format"
PROP_ENABLED = "blendot_enabled"

# Saves that must not export (the initial save right after importing).
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
    if _skip_next_export:
        _skip_next_export = False
        return
    scene = bpy.context.scene
    target = scene.get(PROP_TARGET)
    if not target or not scene.get(PROP_ENABLED, True):
        return
    blend = bpy.data.filepath
    target_abs = os.path.normpath(os.path.join(os.path.dirname(blend), target))
    fmt = scene.get(PROP_FORMAT) or _format_for(target_abs)
    export_asset(target_abs, fmt)
    _write_record(blend, target_abs)
    print(f"Blendot: exported {target_abs}")


def register():
    handlers = bpy.app.handlers.save_post
    if not any(getattr(h, "__name__", "") == "_on_save_post" for h in handlers):
        handlers.append(_on_save_post)


def unregister():
    handlers = bpy.app.handlers.save_post
    for h in [h for h in handlers if getattr(h, "__name__", "") == "_on_save_post"]:
        handlers.remove(h)


# --- launched from Godot -------------------------------------------------------

def _parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {}
    for key, value in zip(argv[::2], argv[1::2]):
        opts[key.lstrip("-")] = value
    return opts


def _open_or_create(target, blend):
    global _skip_next_export
    if os.path.exists(blend):
        bpy.ops.wm.open_mainfile(filepath=blend)
        return None

    bpy.ops.wm.read_homefile(use_empty=True)
    import_asset(target)
    scene = bpy.context.scene
    scene[PROP_TARGET] = os.path.relpath(target, os.path.dirname(blend))
    scene[PROP_FORMAT] = _format_for(target)
    scene[PROP_ENABLED] = True
    _skip_next_export = True  # don't re-export an unedited import
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    _write_record(blend, target)
    return None  # stop the timer


if __name__ == "__main__":
    register()
    opts = _parse_args()
    if "target" in opts and "blend" in opts:
        # Defer until Blender's UI is ready so operators have a valid context.
        bpy.app.timers.register(
            lambda: _open_or_create(opts["target"], opts["blend"]), first_interval=0.1)
