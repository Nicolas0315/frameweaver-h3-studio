"""Export and re-import a deterministic cube as a low-load Blender smoke test."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import bpy


def parse_args() -> argparse.Namespace:
    blender_args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(blender_args)


def main() -> None:
    args = parse_args()
    output = args.output.resolve()
    if output.suffix.lower() != ".glb":
        raise ValueError("--output must use the .glb extension")
    if not output.parent.is_dir():
        raise FileNotFoundError(f"Output directory does not exist: {output.parent}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    bpy.context.active_object.name = "FrameWeaver_QA_Cube"
    bpy.ops.export_scene.gltf(filepath=str(output), export_format="GLB")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(output))
    mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    vertex_count = sum(len(obj.data.vertices) for obj in mesh_objects)
    triangle_count = 0
    for obj in mesh_objects:
        obj.data.calc_loop_triangles()
        triangle_count += len(obj.data.loop_triangles)

    result = {
        "meshObjects": len(mesh_objects),
        "vertices": vertex_count,
        "triangles": triangle_count,
        "output": str(output),
    }

    if len(mesh_objects) != 1 or vertex_count <= 0 or triangle_count != 12:
        raise RuntimeError(f"Unexpected GLB round-trip result: {result}")

    print("FRAMEWEAVER_3D_SMOKE=" + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
