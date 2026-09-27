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
2. Scene-tree `MeshInstance3D` entry with mesh swap + undo. *(done)*
   - Blender's world origin = the node's origin. The main object's offset is baked
     into the node's mesh (so moving it in Blender re-pivots the mesh).
   - Other Blender objects become descendant nodes with Blender's hierarchy and
     origins; matched by a `blendot_id` custom property (glTF extras) so renames
     and reparenting update the same node, keeping Godot-added scripts/children.
   - Godot materials are kept by material name.
   - Project > Tools > "Blendot: Clean Up Unused Blender Files..." lists sidecars
     and meshes no saved or open scene uses, and moves them to the system trash.
   - Editing something already open in Blender raises that window (Hyprland)
     or says so, instead of starting a second Blender on the same .blend.
3. Settings in Project Settings (basic) + Tools menu shortcut. *(done)*
   Convert mode with UID carry-over. *(done)*
   - Setting `blendot/mode`: Sidecar / Convert. In Sidecar mode FBX/glb files also
     get "Convert to .blend..."; in Convert mode "Edit in Blender" converts first.
   - Convert: save scenes, create the .blend (copying an up-to-date sidecar, else a
     background Blender import), write its .import with the old UID and non-format
     import params, trash the old file, rewrite paths in .tscn/.tres, list scripts
     that still mention the old path, rescan and reload open scenes.
   - .blend files get "Edit in Blender" (opens directly; Godot reimports on save).
   - OBJ isn't convertible (imports as a Mesh, not a scene).
   - Nodes: "Save as .blend Asset..." on a MeshInstance3D writes a .blend (from
     its sidecar, so Blender child objects come along) and replaces the node with
     an instance of it: same name/transform, Godot-added children moved over,
     one undo step. Scripts/signals on the node are warned about, not moved.
     Renaming the node after the file is a checkbox, on by default unless scripts
     seem to use the name ($Name, "Name", paths); those lines are listed, never
     edited. Scene references (exported Node/NodePath properties, arrays of them,
     local AnimationPlayer tracks) are retargeted in the same undo step, rename or
     not; animations stored in other files are reported instead.

### FBX round-trip findings (tested on Blender, Maya/Arnold and Mixamo FBX)
- Scale, axes, bones and animation length: stable across repeated round trips.
- Animation names: Blender adds "<object>|" each trip; the bridge strips it on
  import and exports takes under the action name, so names stay unchanged.
- Textures on Arnold/Maya materials (`Maya|baseColor`...) aren't wired by
  Blender's importer; the bridge wires them from the FBX connections. Exports
  embed textures.
- Known loss: roughness/metallic maps. Blender exports roughness as FBX
  "ShininessExponent", which Godot doesn't read as roughness. Base colour and
  normal maps survive. Use glb, or Godot material overrides, where it matters.
- FBX older than 7.1 (e.g. 6100) and ASCII FBX can't be imported by Blender;
  Godot shows an explanation instead of launching an empty Blender.
4. Advanced Import Settings button, export preset tuning, Asset Library release.
