# Gaussian Splats: Easiest End-to-End Workflow

This guide is written for first-time Linux users.

If a command fails, first run:

```bash
cd /home/cam/GassianRobot
```

## 1) Open the full workflow TUI (recommended)

```bash
./scripts/gs_tui.sh
```

For first-time robot operators, use the simplest scan menu:

```bash
./scripts/easy_autonomy_tui.sh
```

For advanced robot control + navigation checks, use the dedicated control center:

```bash
./scripts/control_center.sh
```

For the top-level launcher that points you to the easy scan menu, advanced robot tools, or Gaussian workflow, use:

```bash
./scripts/master_tui.sh
```

Use these top-level menus:
1. Gaussian workflow
2. Run management
3. Docker & environment
4. RTAB-Map / Nav2 / robot ops
5. Diagnostics

Non-destructive self-test:

```bash
./scripts/test_gs_tui.sh
```

## 2) One-time host setup

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip ffmpeg docker.io
sudo usermod -aG docker "$USER"
```

Then log out/in (or reboot) so Docker group permissions apply.

Install camera script deps:

```bash
python3 -m pip install --user --upgrade pip
python3 -m pip install --user depthai opencv-python
```

## 3) Build and validate Docker images

Fast validation (cached):

```bash
./scripts/validate_docker_builds.sh --mode cached --target all
```

Full clean validation (slow, but strongest check):

```bash
./scripts/validate_docker_builds.sh --mode clean --target training
```

## 4) Capture a handheld scan

From TUI:
1. `Gaussian workflow`
2. `Capture handheld scan`

CLI equivalent:

```bash
./scripts/manual_handheld_oak_capture_test.sh
```

This creates a run under `runs/YYYY-MM-DD-...` and includes blur filtering.

## 5) Start training

From TUI:
1. `Gaussian workflow`
2. `Start training`
3. Pick the run from a list

CLI equivalent:

```bash
./scripts/start_gaussian_training_job.sh --run latest --mode prep-train --max-iters 30000
```

Important: `--run latest` is context-aware now.
- For training, latest means latest **trainable** run (`raw/capture.mp4` or `gs_input.env`).
- `runs/camera_health` is automatically excluded from training selection.

## 6) Watch status and logs

```bash
./scripts/training_job_status.sh --run latest
./scripts/watch_gaussian_training_job.sh --run latest
```

Stop a job:

```bash
./scripts/stop_gaussian_training_job.sh --run latest
```

Force stop:

```bash
./scripts/stop_gaussian_training_job.sh --run latest --force
```

## 7) Start viewer

From TUI:
1. `Gaussian workflow`
2. `Start viewer`
3. Pick a viewer-ready run

CLI equivalent:

```bash
./scripts/start_gaussian_viewer.sh --run latest --port 7007
```

Open browser:
- Local: `http://localhost:7007`
- LAN: `http://<jetson-ip>:7007`

Tailscale notes from live Jetson testing:
- Direct viewer access on the tailnet can work at `http://<100.x.y.z>:7007`
- For this Jetson, a dedicated Tailscale-bound proxy was also used successfully at:
  - `http://<100.x.y.z>:8081/`
- Do **not** assume the viewer can be safely mounted under a path prefix like `/splat/` behind another app. The current viewer frontend expects to live at `/` and may show a blank page if proxied under a subpath.
- If you get `Bad gateway: connect ECONNREFUSED 127.0.0.1:7007`, the viewer container likely has not finished startup yet. Wait for the viewer banner in logs before retrying.

Stop viewer:

```bash
./scripts/stop_gaussian_viewer.sh --run latest
```

## 8) Delete/restore runs safely

Soft delete (moves to trash):

```bash
./scripts/delete_run.sh --run latest
```

Restore:

```bash
./scripts/restore_run.sh --list
./scripts/restore_run.sh --entry <trash-entry-name>
```

Purge old trash:

```bash
./scripts/purge_run_trash.sh --older-than-days 30
```

## 9) Troubleshooting: “No active process”

If `watch_gaussian_training_job.sh` says no active process:
1. Check status:
   ```bash
   ./scripts/training_job_status.sh --run latest
   ```
2. If `State: exited` with an exit code:
   - Training started but failed quickly.
   - Open latest log for the real error.
3. If `State: never-started`:
   - No job was launched for that run.
4. If run selection is wrong:
   - Use TUI run selection explicitly instead of typing paths.

## 10) Absolute command path rule (common mistake)

If you are already in `~/GassianRobot/scripts`, do **not** type `./scripts/...`.

Either:
- `cd /home/cam/GassianRobot` then run `./scripts/...`
- or stay in `scripts/` and run `./<script>.sh`
