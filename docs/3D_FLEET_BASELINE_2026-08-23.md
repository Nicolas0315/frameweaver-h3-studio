# 3D fleet baseline — 2026-08-23

Observed read-only between 17:20 and 17:31 JST. Canonical roster: `scripts/fleet-hosts.tsv` in `agent-context`, SHA-256 `405D699D89456B2F64C626BD19C5018C89824C595C4508E77510AD342224A812`.

## NVIDIA workers

| Worker | GPU | VRAM used / free | GPU util | RAM free | Local disk free | ComfyUI | 3D runtime/model | Decision |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| rtx4090 | RTX 4090 24 GB | 4,181 / 19,953 MiB | 0% | 94.5 GiB | D: 2,004.6 GiB | running on 8188 | Blender 4.5 only | Blender smoke ready; 21–24 GB cases deferred |
| rtx5060ti | RTX 5060 Ti 16 GB | 1,662 / 14,633 MiB | 0% | 32.1 GiB | D: 1,658.7 GiB | process detected | none | preferred model-storage and 8–12 GB worker after isolated install |
| nicolas2025 | RTX 3070 8 GB | 815 / 7,224 MiB | 0% | 33.1 GiB | C: 134.1 GiB; F: 34.1 GiB | not detected | none | SF3D preview candidate only; storage constrained |
| nicoyuri | RTX 2070 8 GB | 589 / 7,418 MiB | 0% | 45.6 GiB | C: 319.6 GiB | not detected | none | SF3D preview candidate; preserve training-role priority |

No active training command matched the bounded process probe on the four Windows GPU nodes. This is a point-in-time observation, not a reservation. Every generation must re-run the readiness gate immediately before launch.

The Windows WDDM driver returned `N/A` for per-process VRAM. Scheduling therefore uses fresh device-level free VRAM plus a boolean training-command check; it must not claim process-level VRAM attribution from `nvidia-smi`.

## Apple nodes

| Worker | Hardware | Unified memory | Root disk free | Blender | Local role |
| --- | --- | ---: | ---: | --- | --- |
| home-mac-main | Apple M2 Pro | 16 GiB | about 71.8 GiB | not found | UI/review only; below SF3D's recommended 32 GiB MPS guidance |
| ca-20032518 | Apple M5 Max | 64 GiB | about 301.7 GiB | not found | optional experimental SF3D/MPS evaluation after isolated install |

Apple nodes are not substitutes for the CUDA-only TripoSG/TRELLIS path. Stable Fast 3D documents experimental MPS support, but it remains unverified on these nodes.

## Verified low-load E2E

Blender 4.5 exported and re-imported a deterministic cube on rtx4090:

- exit code: `0`;
- mesh objects: `1`;
- vertices after GLB normal splitting: `24`;
- triangles: `12`;
- GLB size: `1,744` bytes;
- SHA-256: `004880CB3AE9297DAB2503A0BA357AD0025D99415AF18C48CC6965590605D359`;
- observed GPU before/after: `4,181 MiB, 0%` → `4,244 MiB, 0%`.

The same SHA-256 was produced twice. Temporary GLBs were placed under `D:\temp\frameweaver-3d-smoke-*`; automated cleanup was blocked by the executor safety policy, so two 1,744-byte fixtures may remain and are not treated as source artifacts.

## Official requirement cross-check

| Candidate | Official/current requirement | Fleet route |
| --- | --- | --- |
| Stable Fast 3D | about 6 GB VRAM per image; Windows and MPS are experimental | 3070/2070 preview, 5060 Ti fallback, optional M5 Max experiment |
| TripoSG | CUDA GPU with at least 8 GB VRAM | 5060 Ti primary; do not assume an 8 GB WDDM card has enough headroom |
| Hunyuan3D 2.1 | 10 GB shape, 21 GB texture, 29 GB combined | 5060 Ti shape; 4090 texture on demand; never combined locally |
| TRELLIS.2 | Linux only; NVIDIA GPU with at least 24 GB memory | 4090-only isolated Linux/WSL experiment after ComfyUI unload and fresh gate |

## Deferred queue

1. Install SF3D in a version-locked worker on 5060 Ti, then repeat on 3070/2070 only if the fixed three-fixture test remains inside the 1 GiB reserve.
2. Install TripoSG on 5060 Ti and record peak VRAM, wall time, geometry QA, and environment lock hash.
3. Test Hunyuan shape on 5060 Ti. Test paint separately on 4090 during an approved idle window.
4. Test TRELLIS.2 only after an isolated Linux environment exists and the 4090 is not serving ComfyUI or another workload.
5. Keep all fine-tuning blocked until dataset provenance, evaluation fixtures, storage budget, and an owner-approved maintenance window exist.
