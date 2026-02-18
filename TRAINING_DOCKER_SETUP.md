# Gaussian Training Docker Setup (Jetson + RTAB-Map Workflow)

This setup keeps ROS capture and Gaussian training containerized, while sharing the same `runs/` artifacts.
Session summary of concrete changes: `SESSION_HANDOFF_2026-02-17.md`.

## Recommended architecture
- RTAB-Map container (`gassian/ros2-humble-rtabmap:latest`) for ROS, bagging, and mapping.
- Training container (`gassian/gsplat-train:latest`) for Nerfstudio processing/training/export.
- Shared run data under `runs/YYYY-MM-DD-scene/`.

## Why this path
- Reproducible environments.
- Safer dependency isolation on Jetson.
- Easy to rebuild/update either side independently.

## Build images
```bash
chmod +x scripts/*.sh
./scripts/build_rtabmap_image.sh
./scripts/build_training_image.sh
```

Optional: a Compose file is provided at `docker/docker-compose.yml`, but the scripts are the primary path (works even when the Docker Compose plugin is not installed).

## Capture flow
1. Create run folder:
```bash
./scripts/init_run_dir.sh lab_loop_a
```
2. Record raw ROS data:
```bash
RUN_NAME=$(date +%F)-lab_loop_a ./scripts/record_raw_bag.sh
```
3. Record short RGB video into the same run (needed for the current training pipeline):
```bash
ffmpeg -y -f v4l2 -framerate 30 -video_size 1280x720 \
  -i /dev/video0 runs/$(date +%F)-lab_loop_a/raw/capture.mp4
```

## Prepare and train
```bash
./scripts/prepare_gs_input_from_run.sh --run runs/$(date +%F)-lab_loop_a
./scripts/process_train_export.sh --run runs/$(date +%F)-lab_loop_a --from-run-env --downscale 2
```

## Notes on "RTAB-Map data -> Gaussian training"
- This is a good direction, not a bad idea.
- In this repo’s current automated path, training consumes a video in the run folder and keeps RTAB-Map outputs (bag/map/db) as aligned context.
- Next iteration: feed RTAB-Map pose priors directly into a prepared Nerfstudio dataset, then use:
```bash
./scripts/process_train_export.sh --dataset <prepared_dataset_dir> --run runs/<run_name>
```

## Troubleshooting
- If Docker GPU runtime fails, check:
```bash
docker info | grep -nE "Runtimes|nvidia" || true
```
- Training image base note: this repo uses `nvcr.io/nvidia/l4t-pytorch:r35.2.1-pth2.0-py3` (a verified-available Jetson tag).
- The training image includes `libxml2-dev`, `libxslt1-dev`, and `libhdf5-dev` to avoid common ARM64 wheel build failures.
- First build can take a long time because `nerfstudio` pulls a large dependency set on ARM64.
- If `ns-process-data` fails due to missing COLMAP in image, use the `--dataset` mode after preparing dataset externally.
