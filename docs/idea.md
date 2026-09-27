
Blendot:

You: has anyone made an addon that would allow you to rightclick a mesh node in scene or inspector and chose "open as glb in blender"  then do so and when you save blender reverse populate it back in its original place?
  → WebSearch
Claude: I couldn't find an addon that does exactly that (right-click a mesh node, edit it in Blender, and have it land back in the same place).

The closest options:

- **Godot's own `.blend` import (Godot 4):** set the Blender path in Editor Settings → FileSystem → Import → Blender. After that, a `.blend` file in your project imports like a `.glb`, and re-imports whenever you save it in Blender. That covers the "save in Blender and it updates in Godot" half. The export step is still manual: Mesh → Export as glTF, then open that file in Blender and save it as a `.blend`.
- **[Blender-Godot Pipeline](https://michaeljared.itch.io/blender-to-godot-4-pipeline-addon):** a Blender addon for sending whole scenes from Blender to Godot, not editing one mesh from Godot.

The missing piece is a small Godot editor plugin, and it would be fairly simple. It would:
1. Add a right-click menu item on MeshInstance3D nodes.
2. Export that mesh to `res://blender_edits/&lt;name&gt;.glb` and open it in Blender.
3. Watch for Blender to save back to the same file, then re-import it and replace the node's mesh while keeping its position and material.

I could build this, either in this project or as a tool in GodotLiveMCP. Just say which.

Sources:
- [Blender to Godot 4 Pipeline Addon (itch.io)](https://michaeljared.itch.io/blender-to-godot-4-pipeline-addon)
- [Superhive docs](https://superhivemarket.com/products/blender-godot-pipeline-addon/docs)
- [Codebycandle: Blender-Godot workflow](https://codebycandle.com/blog/blender-godot-workflow)
You: has anyone made an addon that would allow you to rightclick a mesh node in scene or inspector and chose "open as glb in blender"  then do so and when you save blender reverse populate it back in its original place?
  → WebSearch
Claude: I couldn't find an addon that does exactly that (right-click a mesh node, edit it in Blender, and have it land back in the same place).

The closest options:

- **Godot's own `.blend` import (Godot 4):** set the Blender path in Editor Settings → FileSystem → Import → Blender. After that, a `.blend` file in your project imports like a `.glb`, and re-imports whenever you save it in Blender. That covers the "save in Blender and it updates in Godot" half. The export step is still manual: Mesh → Export as glTF, then open that file in Blender and save it as a `.blend`.
- **[Blender-Godot Pipeline](https://michaeljared.itch.io/blender-to-godot-4-pipeline-addon):** a Blender addon for sending whole scenes from Blender to Godot, not editing one mesh from Godot.

The missing piece is a small Godot editor plugin, and it would be fairly simple. It would:
1. Add a right-click menu item on MeshInstance3D nodes.
2. Export that mesh to `res://blender_edits/&lt;name&gt;.glb` and open it in Blender.
3. Watch for Blender to save back to the same file, then re-import it and replace the node's mesh while keeping its position and material.

I could build this, either in this project or as a tool in GodotLiveMCP. Just say which.

Sources:
- [Blender to Godot 4 Pipeline Addon (itch.io)](https://michaeljared.itch.io/blender-to-godot-4-pipeline-addon)
- [Superhive docs](https://superhivemarket.com/products/blender-godot-pipeline-addon/docs)
- [Codebycandle: Blender-Godot workflow](https://codebycandle.com/blog/blender-godot-workflow)
