# 3D generation validation runbook

## Objective

Keep image/video ComfyUI stable while adding a reproducible 3D path. Model runtimes live in isolated workers; Blender is the deterministic post-process and QA boundary. This runbook never treats Blender MCP as the model generator.

## Pipeline and ownership

1. **Brief and references** — Freeze front/side/back references, scale, target platform, polygon budget, texture resolution, seed, and license provenance.
2. **Pre-process** — Remove background, normalize framing, and create multiview references in ComfyUI when useful.
3. **Geometry** — Use a dedicated worker: SF3D for previews, TripoSG/Hunyuan shape for geometry, or TRELLIS.2 for high-end PBR candidates.
4. **Topology and UV** — Validate manifoldness, normals, connected components, triangle count, UV overlap, and texel density. Remesh only against an explicit target.
5. **Texture** — Generate PBR maps in an isolated texture worker. Record color space and channel packing.
6. **Blender headless QA** — Import, apply transforms, inspect bounds/materials, render turntable frames, and export GLB. This is deterministic and suitable for CI.
7. **Human review** — Review silhouette, identity/detail fidelity, topology around deformation, material response, scale, and intended animation before acceptance.
8. **Publish** — Preserve the source asset, generated candidate, QA report, human decision, tool/model commit, seed, and final export separately.

## Scheduling gates

Run `powershell.exe -NoProfile -File scripts/Test-3DReadiness.ps1` on a Windows GPU worker. It is read-only and does not start a model or Blender. A case is deferred when any gate applies:

- detected training command;
- GPU utilization above 10%;
- total VRAM below the model's official minimum;
- free VRAM below estimated runtime VRAM plus 1 GiB reserve;
- required model not explicitly declared with `-InstalledModelId`;
- required executable not installed;
- the manifest marks training as policy-deferred.

Example after a model is installed in its isolated environment:

```powershell
powershell.exe -NoProfile -File scripts/Test-3DReadiness.ps1 `
  -InstalledModelId stable-fast-3d
```

Test the scheduler logic without a GPU:

```powershell
powershell.exe -NoProfile -File scripts/Test-3DReadiness.ps1 -SelfTest
```

Run the low-load Blender export/re-import smoke test into an existing temporary directory:

```powershell
& 'C:\Program Files\Blender Foundation\Blender 4.5\blender.exe' `
  --background --factory-startup `
  --python scripts/blender-headless-smoke.py -- `
  --output "$env:TEMP\frameweaver-3d-smoke\cube.glb"
```

## Fixed validation inputs

Each executable model test must use the same three approved, non-sensitive fixtures:

- a matte, asymmetrical hard-surface product on a plain background;
- a stylized character in neutral A-pose with front/side/back views;
- a soft organic object with visible concavities.

Record input SHA-256, seed, model/repository commit, environment lock hash, CLI arguments, peak VRAM, wall time, output SHA-256, and failure log. Do not use a visually attractive result as a substitute for geometry checks.

## Quality gates

| Stage | Automated gate | Human gate |
| --- | --- | --- |
| Geometry | non-empty mesh, finite vertices, manifold/normal/component report, bounds and scale | silhouette and reference fidelity |
| Topology | triangle count and UV overlap within target, no accidental disconnected debris | deformation-ready edge flow when rigging |
| PBR | required maps exist, expected dimensions/color spaces, no NaN pixels | material response under neutral HDRI and hard light |
| Rig | named skeleton, bounded weights, animation smoke test | pose quality and unacceptable collapse |
| Export | GLB re-import succeeds and round-trip counts are recorded | target-viewer appearance |

## Model isolation and deferred queue

- Do not install ComfyUI-3D-Pack into the production image/video ComfyUI environment. Its CUDA/PyTorch extensions belong in a version-locked worker or container.
- Keep model weights on a data drive and keep environment caches, outputs, and logs in separate directories. Do not use the repository as a model cache.
- SF3D and TripoSG are the first local candidates for 8–16 GiB workers.
- Hunyuan3D 2.1 Paint and TRELLIS.2 are 4090-only, on-demand candidates. They remain deferred whenever the 4090 has an existing workload or cannot retain the manifest reserve.
- Fine-tuning remains deferred until a dedicated dataset, license review, evaluation set, storage budget, and owner-approved maintenance window exist.

## Research boundary

Tripo's hosted product is an end-to-end proprietary service; ComfyUI and Blender MCP are integration/orchestration options, not evidence of Tripo's private implementation. Public local candidates should be evaluated from their official repositories:

- TripoSG: https://github.com/VAST-AI-Research/TripoSG
- Stable Fast 3D: https://github.com/Stability-AI/stable-fast-3d
- Hunyuan3D 2.1: https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1
- TRELLIS.2: https://github.com/microsoft/TRELLIS.2
- ComfyUI-3D-Pack: https://github.com/MrForExample/ComfyUI-3D-Pack
