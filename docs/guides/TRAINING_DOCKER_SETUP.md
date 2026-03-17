# Training Docker Setup (Jetson)

Technical reference for Docker build + validation.

If unsure of current directory:

```bash
cd /home/cam/GassianRobot
```

## 1) Build all training images

```bash
./scripts/build_jetson_training_images.sh
```

Available build flags:

```bash
./scripts/build_jetson_training_images.sh --no-cache --pull --progress plain
```

Supported flags:
- `--no-cache`
- `--pull`
- `--progress <auto|plain|tty>`
- `--dry-run`

Image chain built in order:
1. `gassian/gsplat-train:latest`
2. `gassian/gsplat-train:colmap`
3. `gassian/gsplat-train:cuda-colmap`
4. `gassian/gsplat-train:jetson-compatible`

## 2) Validate builds (recommended)

Fast cached validation:

```bash
./scripts/validate_docker_builds.sh --mode cached --target all
```

Slow clean validation:

```bash
./scripts/validate_docker_builds.sh --mode clean --target training
```

Targets:
- `training`
- `rtabmap`
- `all`

Modes:
- `cached`: normal cached build
- `clean`: `--no-cache --pull` rebuild

Validation checks include:
- Training image: `pip show nerfstudio gsplat`, `colmap -h`, `ns-train --help`
- RTAB-Map image: `ros2 pkg list | grep rtabmap_ros`

Script exits nonzero if any check fails.

## 3) `h5py` / `mpi.h` build failure notes

Previous Jetson failure was:

```text
fatal error: mpi.h: No such file or directory
```

Current `docker/gsplat_train.Dockerfile` mitigates this by:
- Installing `python3-h5py` via apt
- Setting `HDF5_DIR=/usr/lib/aarch64-linux-gnu/hdf5/serial` for pip install fallback

If you still see build issues, run clean validation and inspect the failing layer output.

## 4) Training job scripts (long-running workflow)

Start:

```bash
./scripts/start_gaussian_training_job.sh --run latest --mode prep-train --max-iters 30000
```

Status:

```bash
./scripts/training_job_status.sh --run latest
```

Watch logs:

```bash
./scripts/watch_gaussian_training_job.sh --run latest
```

Stop:

```bash
./scripts/stop_gaussian_training_job.sh --run latest
```

Run status metadata file:
- `runs/<run>/logs/train_job.status`

## 5) Context-aware run targeting

`latest` is no longer “blind newest run”.

It is filtered by script context:
- Training start: latest **trainable** run
- Viewer start/stop: latest **viewer-ready** run
- Log watch: latest run with training logs
- Stop training: latest run with training metadata

This prevents accidental selection of `runs/camera_health` for training.

## 6) TUI coverage

Use full workflow TUI:

```bash
./scripts/gs_tui.sh
```

Detailed menu map:
- `docs/guides/TUI_FULL_WORKFLOW_REFERENCE.md`
