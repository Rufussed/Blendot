# Blendot — plan

Edit Godot assets in Blender; every Blender save flows back into Godot.

Targets: Godot 4.4+ (developed on 4.7), Blender 4.2+ (developed on 5.2).

## Modes (project setting)

- **Sidecar (default).** A `.blend` is kept in `res://.blendot/` as the editable
  source. Each Blender save also exports over the original asset (`.fbx`, `.glb`,
  `.gltf`, `.obj`), so Godot references never change.
- **Convert.** Replace the asset with a `.blend` Godot imports natively, carrying
  over the UID and import settings. Files only. Needs Blender on every machine.

## Entry points

| Entry | Slot | Target on save |
|---|---|---|
| Right-click asset in FileSystem dock | `CONTEXT_SLOT_FILESYSTEM` | Overwrite the asset; Godot reimports |
| Right-click `MeshInstance3D` in Scene tree | `CONTEXT_SLOT_SCENE_TREE` | `.glb` in sidecar dir; plugin swaps node mesh (undoable) |
| Advanced Import Settings panel | injected button (fragile, later) | same as FileSystem |

## Blender side: `blendot_bridge.py`

Passed by Godot at launch: `blender --python blendot_bridge.py -- --target <asset> --blend <file.blend>`.
It opens (or creates from the asset) the sidecar `.blend`, and for that Blender
session only, each save of that exact `.blend` exports to the asset and writes
`<blend>.json` with the asset's SHA-256.

Deliberately **not** an installed addon, and nothing is stored in the `.blend`:
opened directly in Blender it's a plain file, and "Save As" elsewhere never
exports. Exporting only happens when the edit was started from Godot.

## Stale-source detection (teams)

On "Edit in Blender" in sidecar mode, Godot compares the asset's SHA-256 with
the hash last recorded in `<blend>.json`:
- same -> open the `.blend`;
- different (a teammate changed the asset) -> ask: **Use new file** (back up
  `.blend` to `.blend.bak`, rebuild from the asset) / **Keep my .blend** (next save
  overwrites theirs) / Cancel. A project setting can make this automatic.

## Settings

| Setting | Scope | Default |
|---|---|---|
| Blender executable | Editor | Godot's `filesystem/import/blender/blender_path`, else `blender` |
| Mode (sidecar/convert) | Project | sidecar |
| Sidecar dir | Project | `res://.blendot/` |
| On external change (ask/use new/keep mine) | Project | ask |
| Commit .blend files | Project | off (adds to `.gitignore`) |
| Export presets per format | Project | tuned for Godot import |

## Milestones

1. **FileSystem right-click, sidecar mode.** Create/open `.blend`, export on save,
   stale-hash dialog, Godot rescans on change. *(done)*
2. Scene-tree `MeshInstance3D` entry with mesh swap + undo.
3. Settings panel; convert mode with UID carry-over.
4. Advanced Import Settings button, export preset tuning, Asset Library release.
