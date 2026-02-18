#!/usr/bin/env bash
set -euo pipefail

# Create a standard run folder: runs/YYYY-MM-DD-scene-name/
# Usage: ./scripts/init_run_dir.sh office_loop_a

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scene-name>"
  exit 1
fi

scene_name="$1"
date_stamp="${DATE_STAMP:-$(date +%F)}"
run_root="${RUN_ROOT:-runs}"
run_dir="${run_root}/${date_stamp}-${scene_name}"

mkdir -p "$run_dir"/{raw,frames,colmap,dataset,checkpoints,exports,logs}

cat > "${run_dir}/run_sheet.env" <<EOF
# Run metadata for ${date_stamp}-${scene_name}
RUN_NAME=${date_stamp}-${scene_name}
ROBOT_BASE=irobot_create3
LIDAR=rplidar_a1
CAMERA=oak_d_pro
COMPUTE=jetson_orin_nano_8gb
NOTES=
EOF

cat > "${run_dir}/README.md" <<EOF
# Run ${date_stamp}-${scene_name}

Folders:
- raw: raw capture files (video/rosbag)
- frames: extracted image frames
- colmap: COLMAP artifacts and sparse model
- dataset: processed dataset used by nerfstudio
- checkpoints: training outputs/checkpoints
- exports: final exported splats
- logs: command logs and diagnostics

Files:
- run_sheet.env: metadata and run configuration snapshot
EOF

echo "Created ${run_dir}"
