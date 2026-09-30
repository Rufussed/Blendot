# Handover

Where Blendot stands, and how to pick it up on another machine. The full design and history are in `PLAN.md`; user-facing docs are in `README.md`.

## State (2026-09-30)

All milestones are done and pushed to https://github.com/Rufussed/Blendot (public, MIT):

- **Model files:** Edit in Blender for FBX, glb, gltf and obj (sidecar mode), from the FileSystem dock and the import dialog. FBX round trips are fixed.
- **Nodes:** Edit in Blender on a `MeshInstance3D`, with Blender objects coming back as child nodes (hierarchy, origins, stable IDs).
- **`.blend` files:** convert a model file to a `.blend` (keeps its UID), and **Save as .blend Asset** for nodes, with reference updating.
- **Housekeeping:** cleanup of unused files, the "already open in Blender" check, settings shortcut, undo steps that survive plugin reloads.

Tested on Godot 4.7.2 and Blender 5.2.1, Linux/Hyprland only.

## Set up on a new machine

```
git clone https://github.com/Rufussed/Blendot.git
godot -e --path Blendot
```

- The repo is itself the test project, and the plugin is already enabled in `project.godot`.
- Blender must be on `PATH`, or set in Editor Settings → Blendot → Blender Path.
- The test scenes and models weren't committed. Make a fresh `MeshInstance3D` or drop in an FBX to test.
- **GodotLiveMCP (optional, for Claude):** symlink its addon to `addons/godot_live_mcp`, then enable it and its `RuntimeBridge` autoload. The path is already in `.gitignore`.
- **Pushing:** this machine pushed over HTTPS with `gh` (no SSH key). Either run `gh auth setup-git` once, or add an SSH key.

## Gotchas when developing

- **Reload after editing a script:** switch Blendot off and on in Project Settings → Plugins. If a script failed to compile while the editor was open, the cached copy can be corrupted ("Internal script error"). Restart the editor (Project → Reload Current Project).
- **Don't test in real scenes.** Use a throwaway scratch scene in its own tab, and never undo past your own test steps. Stale undo steps once deleted a real node.
- **Undo steps must only call built-in Node methods.** Steps that call plugin code break after a reload.
- **glTF differs between editor and runtime.** In the editor it gives `ImporterMeshInstance3D` (handled in `_mesh_of`), and headless tests don't catch that.
- **Blender runs in the background** (`blender -b`) for conversions. `bpy.app.timers` don't fire in that mode, so the bridge calls those functions directly.

## Next ideas

- Move signal connections when replacing a node (currently only counted and warned about).
- A Blendot dock listing open Blender sessions.
- Asset Library listing: needs an icon and screenshots, then submit under your account.
- Test on Windows and macOS: Blender path detection, `OS.move_to_trash`, and window focusing (currently only on Hyprland).
