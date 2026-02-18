# Runs Folder Convention

Each capture/training attempt should live in:

`runs/YYYY-MM-DD-scene-name/`

Create one with:

```bash
./scripts/init_run_dir.sh scene_name
```

Expected structure:
- `raw/`: raw videos and/or rosbags
- `frames/`: extracted frames
- `colmap/`: COLMAP outputs
- `dataset/`: processed Nerfstudio dataset
- `checkpoints/`: model outputs
- `exports/`: exported splats and deliverables
- `logs/`: command logs and diagnostics
- `run_sheet.env`: run metadata snapshot
