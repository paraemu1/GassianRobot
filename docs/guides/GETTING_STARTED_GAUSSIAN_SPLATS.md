# Gaussian Splats on Jetson: Beginner Start Guide

This guide is for first-time users. It assumes no Linux background and gives copy/paste commands.

## What you get at the end
- A captured camera run under `runs/...`
- A trained Gaussian Splat model
- A web viewer you can open in a browser

## 1) Open a terminal in this project
```bash
cd /home/cam/GassianRobot
```

Use this one-liner before running any command (safe if you forgot where you are):
```bash
cd /home/cam/GassianRobot
```

## 1.5) Easiest mode: open the menu app (TUI)
```bash
./scripts/gs_tui.sh
```
If this is all you use, that is fine.

## 2) Install required host tools (one time)
```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip ffmpeg docker.io
```

Add your user to the Docker group (one time):
```bash
sudo usermod -aG docker "$USER"
```
Then log out and log back in (or reboot) so Docker permissions apply.

Install Python packages used by camera scripts:
```bash
python3 -m pip install --user --upgrade pip
python3 -m pip install --user depthai opencv-python
```

## 3) Verify camera health (recommended)
```bash
./scripts/oak_camera_health_check.sh
```
If this fails, fix camera/USB before continuing.

## 4) Build training Docker images (one time)
This can take a long time on Jetson.
```bash
./scripts/build_jetson_training_images.sh
```

## 5) Capture data from the OAK camera
### Option A (recommended): handheld manual test script
Run this, move the camera around by hand, then stop when prompted.
```bash
./scripts/manual_handheld_oak_capture_test.sh
```
This creates a new run folder under `runs/`.

It also applies blur filtering and prepares `gs_input.env` automatically.

### Option B: fully automated capture + train pipeline
```bash
./scripts/capture_and_train_from_camera.sh --scene lab_test --source oak --duration 20 --downscale 2
```

## 6) Start long training in the background
Use this for runs that take a long time.
```bash
./scripts/start_gaussian_training_job.sh \
  --run latest \
  --mode prep-train \
  --max-iters 30000
```

Notes:
- `--mode prep-train` runs blur-filtered prep + train + export.
- `--mode train` skips prep and only trains/exports.
- `--max-iters` controls training length (higher = longer training).
- `--run latest` means "use newest run automatically".

## 7) Watch training logs
```bash
./scripts/watch_gaussian_training_job.sh --run latest
```

Stop a running job if needed:
```bash
./scripts/stop_gaussian_training_job.sh --run latest
```
Force stop:
```bash
./scripts/stop_gaussian_training_job.sh --run latest --force
```

## 8) Start web viewer
After training finishes:
```bash
./scripts/start_gaussian_viewer.sh --run latest --port 7007
```

Open in browser:
- On Jetson: `http://localhost:7007`
- On another device in same network: `http://<jetson-ip>:7007`

Stop viewer:
```bash
./scripts/stop_gaussian_viewer.sh --run latest
```

## 9) Train an existing run you already captured
If you already have run data and just want training:
```bash
./scripts/start_gaussian_training_job.sh --run latest --mode train --max-iters 30000
```

If you want to re-run prep with stronger blur filtering first:
```bash
./scripts/run_handheld_prep_or_train.sh --run latest --mode prep --blur-threshold 6
```
Then start training with `--mode train`.

## 10) Where outputs are saved
For each run (`runs/<run-name>/`):
- Input video: `raw/capture.mp4`
- Prepared dataset: `dataset/`
- Training logs: `logs/ns-*.log`
- Training checkpoints: `checkpoints/.../nerfstudio_models/`
- Exported splat: `exports/splat/splat.ply`

## 11) Common problems
- `bash: ./scripts/<name>.sh: No such file or directory`:
  - You are probably already inside `~/GassianRobot/scripts`.
  - Fix:
    - `cd /home/cam/GassianRobot`
    - or run without `scripts/`, for example: `./start_gaussian_training_job.sh --run latest ...`
- `Docker daemon is not reachable`:
  - Start Docker: `sudo systemctl start docker`
- `permission denied` with Docker:
  - Ensure `usermod -aG docker $USER` was done, then log out/in.
- Very poor reconstruction quality:
  - Capture slower camera motion, more overlap, better lighting.
  - Increase capture duration.
  - Re-run prep with stronger blur filtering.
- Viewer not reachable:
  - Confirm viewer is running via `docker ps`.
  - Check firewall/network and the selected port.
- Not sure what run names exist:
  - `./scripts/list_runs.sh`

## 12) Minimal repeat workflow (day-to-day)
1. Capture: `./scripts/manual_handheld_oak_capture_test.sh`
2. Train: `./scripts/start_gaussian_training_job.sh --run latest --mode prep-train --max-iters 30000`
3. Watch: `./scripts/watch_gaussian_training_job.sh --run latest`
4. View: `./scripts/start_gaussian_viewer.sh --run latest --port 7007`

## Extra safety tips
- If you are inside `~/GassianRobot/scripts`, do **not** type `./scripts/...`; use `./<script>.sh` or `cd /home/cam/GassianRobot` first.
- `--run latest` is the safest option to avoid typo/path mistakes.
- You can skip command typing completely with `./scripts/gs_tui.sh`.
