# Gaussian Training Docker Setup (Jetson)

This file is the technical companion to the beginner guide:
- Start here first: `docs/guides/GETTING_STARTED_GAUSSIAN_SPLATS.md`

Use this document when you want more control over image builds, scripts, and pipeline internals.

Before running commands, if unsure of your location:
```bash
cd /home/cam/GassianRobot
```

Menu app (TUI) for minimal typing:
```bash
./scripts/gs_tui.sh
```

## Core architecture
- Capture scripts run on host and write into `runs/<run-name>/...`
- Training runs in Docker with GPU runtime enabled
- Nerfstudio pipeline does: process -> train -> export

Main training script:
- `scripts/process_train_export.sh`

Default image used by training scripts:
- `gassian/gsplat-train:jetson-compatible`

## Image build chain
Build all required tags in order:
```bash
./scripts/build_jetson_training_images.sh
```

This produces:
1. `gassian/gsplat-train:latest`
2. `gassian/gsplat-train:colmap`
3. `gassian/gsplat-train:cuda-colmap`
4. `gassian/gsplat-train:jetson-compatible` (final runtime image)

## Capture and training entry points
### Handheld flow
- Capture: `./scripts/manual_handheld_oak_capture_test.sh`
- Prep/train: `./scripts/run_handheld_prep_or_train.sh --mode prep-train`

### Long-running job control scripts
- Start background training:
```bash
./scripts/start_gaussian_training_job.sh --run latest --mode prep-train --max-iters 30000
```
- Watch logs:
```bash
./scripts/watch_gaussian_training_job.sh --run latest
```
- Stop job:
```bash
./scripts/stop_gaussian_training_job.sh --run latest
```
- List available run folders:
```bash
./scripts/list_runs.sh
```

### One-shot camera + train flow
```bash
./scripts/capture_and_train_from_camera.sh --scene lab_test --source oak --duration 20 --downscale 2
```

## Viewer scripts
- Start web viewer:
```bash
./scripts/start_gaussian_viewer.sh --run latest --port 7007
```
- Stop viewer:
```bash
./scripts/stop_gaussian_viewer.sh --run latest
```

## Important environment variables
Training behavior can be overridden without editing scripts:
- `TRAIN_IMAGE`: Docker image tag used by training scripts
- `TRAIN_EXTRA_ARGS`: Extra `ns-train` args (for example iterations)
- `PROCESS_GPU`: `1` enables GPU SIFT in COLMAP process stage

Example:
```bash
TRAIN_IMAGE=gassian/gsplat-train:jetson-compatible \
TRAIN_EXTRA_ARGS='--max-num-iterations 50000 --vis tensorboard' \
PROCESS_GPU=0 \
./scripts/process_train_export.sh --run runs/<run-name> --from-run-env --downscale 2
```

## Input/output contract for a run
Expected run layout:
- Input video: `runs/<run>/raw/capture.mp4`
- Prepared pointer: `runs/<run>/gs_input.env`

Outputs:
- Dataset: `runs/<run>/dataset/`
- Checkpoints: `runs/<run>/checkpoints/...`
- Export: `runs/<run>/exports/splat/splat.ply`
- Logs: `runs/<run>/logs/ns-process-data.log`, `ns-train.log`, `ns-export.log`

## Blur filtering behavior
- `manual_handheld_oak_capture_test.sh` filters blur by default
- `run_handheld_prep_or_train.sh` supports `--blur-threshold`
- Existing runs can be re-prepped with higher threshold:
```bash
./scripts/run_handheld_prep_or_train.sh --run runs/<run-name> --mode prep --blur-threshold 6
```

## Troubleshooting quick checks
Docker runtime:
```bash
docker info | grep -nE 'Runtimes|nvidia' || true
```

Camera:
```bash
./scripts/oak_camera_health_check.sh
```

Latest logs in a run:
```bash
ls -lt runs/<run-name>/logs
```
