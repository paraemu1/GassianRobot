# Runs Index

Each capture or training attempt should live under:

`runs/YYYY-MM-DD-scene-name/`

Create one with:

```bash
./scripts/init_run_dir.sh scene_name
```

## Standard Layout

- `raw/`: source captures such as RGB video or ROS bags
- `frames/`: extracted frames and filtered image sets
- `colmap/`: pose-recovery outputs
- `dataset/`: processed training dataset
- `checkpoints/`: training outputs and configs
- `exports/`: final splats and deliverables
- `logs/`: command logs and diagnostics
- `run_sheet.env`: metadata snapshot for the run

## Special Entries

- `_template/`: scaffold used for new runs
- `.trash/`: soft-deleted runs kept for recovery
- `camera_health/`: utility output directory, not automatically a trainable run

## Operational Notes

- Soft delete moves runs into `runs/.trash/`; use `./scripts/delete_run.sh` and `./scripts/restore_run.sh` instead of removing directories manually.
- Training and viewer scripts may use context-aware `latest`, but trainability/viewer readiness still depends on the expected files being present.
