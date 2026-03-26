# Jetson Verified Status (2026-03-16)

This note records what was actually validated on the current Jetson, so future work can distinguish between planned workflow and proven workflow.

## Machine state
- Host is a Jetson-class device used as the main robotics / training machine.
- `apt-get update` and `apt-get upgrade -y` completed successfully with:
  - `0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded`

## RTAB-Map / autonomy

### Verified
- `./scripts/build/software_readiness_audit.sh` passed with no hard failures.
- Docker daemon reachable.
- RTAB-Map image present: `gassian/ros2-humble-rtabmap:latest`
- `./scripts/build/validate_docker_builds.sh --mode cached --target rtabmap` passed.
- RTAB-Map launch package resolved successfully.
- RTAB-Map + RGB-D odometry smoke test launched successfully inside Docker.

### Not yet verified live
- robot connected and reachable during the same session
- active OAK camera topics feeding RTAB-Map
- active odometry feeding RTAB-Map
- successful Nav2 mission execution on hardware

### Observed blockers
- `l4tbr0` existed but was down during audit.
- Create 3 endpoint was not reachable during audit.
- RTAB-Map produced missing-topic warnings because no live publishers were active.

## Gaussian splats

### Verified
- `./scripts/build/validate_docker_builds.sh --mode cached --target training` passed.
- Training image chain built successfully:
  - `gassian/gsplat-train:latest`
  - `gassian/gsplat-train:colmap`
  - `gassian/gsplat-train:cuda-colmap`
  - `gassian/gsplat-train:jetson-compatible`
- Training image verification passed for Nerfstudio / gsplat / COLMAP / `ns-train`.
- A public internet dataset test was completed using NVIDIA `instant-ngp` fox sample data.
- A 500-step `splatfacto` run completed successfully on this Jetson.
- Export to `.ply` completed successfully.
- Viewer was served successfully over Tailscale via a dedicated proxy port.

### Practical conclusion
- Small practical Jetson-side 3DGS runs are working.
- Better visual quality requires longer training and/or better datasets.
- Existing project run `runs/2026-02-23-manual_handheld_oak_camera_motion_test` was viewer-loadable but appeared weak / undertrained.

## Tailscale / viewer access

### Verified addresses
- Tailnet IP was active during testing.
- Viewer reachable directly on port `7007` when ready.
- Dedicated Tailscale-bound proxy on `:8081` worked for viewer access at root.
- Confirmed working viewer URL after regression/fix:
  - `http://100.65.59.46:8081/`

### Important launch caveat
A later regression happened when the viewer was relaunched manually with a plain Docker port-mapped invocation instead of the project script / proven Jetson settings.
That broken launch path failed with:
- `RuntimeError: CUDA driver version is insufficient for CUDA runtime version`

The reliable launch pattern on this Jetson is:
- use `./scripts/gaussian/start_gaussian_viewer.sh ...`
- which in turn uses:
  - `--runtime nvidia`
  - `--network host`
  - `--ipc host`

Practical rule:
- do **not** substitute a casual `docker run -p 7007:7007 ... ns-viewer ...` command unless you have re-verified the runtime assumptions.

### Important proxy caveat
The current viewer frontend expects to be served from `/`.
Do not assume it will work correctly behind a path prefix like `/splat/` under another web app.
A subpath proxy can return HTML and still render as a blank page because static asset paths are absolute.

## Useful artifacts from this session
- Public internet test run:
  - `runs/2026-03-16-internet_poster_test/`
- Exported splat:
  - `runs/2026-03-16-internet_poster_test/exports/internet_fox_splat/splat.ply`
- 500-step training log:
  - `runs/2026-03-16-internet_poster_test/logs/internet_fox_ns_train.log`
- Longer follow-up training log:
  - `runs/2026-03-16-internet_poster_test/logs/internet_fox_ns_train_3000.log`

## Recommended next steps
1. Complete a longer training pass on the public fox dataset and compare quality.
2. Run a live robot + OAK connectivity session and confirm RTAB-Map with real topics.
3. Capture a cleaner real project dataset and train it with a Jetson-friendly preset.
4. Document a stable viewer publishing pattern for Tailscale access.
5. Preserve the working OpenClaw tailnet setup for future rebuilds. See:
   - `docs/operations/OPENCLAW_TAILSCALE_WEBUI_NOAUTH_SETUP.md`
