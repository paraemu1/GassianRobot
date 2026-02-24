#!/usr/bin/env python3
"""Manual handheld OAK camera motion test capture.

Run this from an IDE "Run" button or terminal. The script will:
1) Create a labeled run folder
2) Wait for you to start
3) Record OAK RGB video while you move the camera by hand
4) Extract sampled JPG frames
5) Prepare gs_input.env for training
"""

from __future__ import annotations

import argparse
import datetime as dt
import subprocess
import sys
from pathlib import Path


TEST_LABEL = "manual_handheld_oak_camera_motion_test"
MARKER_FILENAME = "HANDHELD_CAMERA_MOTION_TEST.txt"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_checked(cmd: list[str], cwd: Path) -> None:
    print("$ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=str(cwd), check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manual handheld OAK capture test")
    parser.add_argument(
        "--scene",
        default=TEST_LABEL,
        help=f"Scene name used in run folder (default: {TEST_LABEL})",
    )
    parser.add_argument("--duration", type=float, default=20.0, help="Capture duration in seconds")
    parser.add_argument("--width", type=int, default=1280, help="Capture width")
    parser.add_argument("--height", type=int, default=720, help="Capture height")
    parser.add_argument("--fps", type=float, default=30.0, help="Capture FPS")
    parser.add_argument("--sensor-resolution", choices=["1080p", "4k", "12mp"], default="1080p")
    parser.add_argument(
        "--frame-sample-fps",
        type=float,
        default=3.0,
        help="Sampled JPG extraction FPS for quick inspection",
    )
    parser.add_argument(
        "--blur-threshold",
        type=float,
        default=4.0,
        help="Laplacian variance threshold to keep frames (default: 4.0). Use <=0 to disable.",
    )
    parser.add_argument(
        "--no-prompt",
        action="store_true",
        help="Start capture immediately (skip Enter prompt)",
    )
    return parser.parse_args()


def create_run_folder(root: Path, scene: str) -> Path:
    scripts_dir = root / "scripts"
    runs_dir = root / "runs"
    date_stamp = dt.date.today().isoformat()
    run_dir = runs_dir / f"{date_stamp}-{scene}"

    if run_dir.exists():
        scene = f"{scene}_{dt.datetime.now().strftime('%H%M%S')}"
        run_dir = runs_dir / f"{date_stamp}-{scene}"

    run_checked([str(scripts_dir / "init_run_dir.sh"), scene], cwd=root)
    return run_dir


def label_run(run_dir: Path, blur_threshold: float) -> None:
    marker_path = run_dir / MARKER_FILENAME
    marker_path.write_text(
        "Manual handheld OAK camera motion test.\n"
        "Recorded to validate quick capture quality for Gaussian training.\n",
        encoding="utf-8",
    )

    run_sheet = run_dir / "run_sheet.env"
    with run_sheet.open("a", encoding="utf-8") as f:
        f.write(f"TEST_LABEL={TEST_LABEL}\n")
        f.write("CAPTURE_STYLE=handheld_manual_motion\n")
        f.write(f"BLUR_FILTER_THRESHOLD={blur_threshold}\n")


def main() -> int:
    args = parse_args()
    root = repo_root()
    scripts_dir = root / "scripts"

    try:
        run_dir = create_run_folder(root, args.scene)
        label_run(run_dir, args.blur_threshold)
        (run_dir / "raw" / "images").mkdir(parents=True, exist_ok=True)
        (run_dir / "logs").mkdir(parents=True, exist_ok=True)

        print("\n=== Manual Handheld Camera Motion Test ===")
        print("Move the OAK camera by hand slowly with smooth motion.")
        print("Try to get overlap and parallax around the scene.")
        print(f"Capture duration: {args.duration:.1f}s")
        print(f"Run folder: {run_dir}")
        print(f"Blur filter threshold: {args.blur_threshold}")

        if not args.no_prompt:
            input("\nPress Enter to start recording...")

        capture_raw_mp4 = run_dir / "raw" / "capture_raw.mp4"
        capture_mp4 = run_dir / "raw" / "capture.mp4"
        run_checked(
            [
                str(scripts_dir / "record_oak_rgb_video.sh"),
                "--output",
                str(capture_raw_mp4),
                "--duration",
                str(args.duration),
                "--width",
                str(args.width),
                "--height",
                str(args.height),
                "--fps",
                str(args.fps),
                "--sensor-resolution",
                args.sensor_resolution,
            ],
            cwd=root,
        )

        run_checked(
            [
                str(scripts_dir / "filter_blurry_video_frames.sh"),
                "--input",
                str(capture_raw_mp4),
                "--output",
                str(capture_mp4),
                "--threshold",
                str(args.blur_threshold),
                "--report-csv",
                str(run_dir / "logs" / "blur_filter_report.csv"),
            ],
            cwd=root,
        )

        frames_out = run_dir / "raw" / "images" / "frame_%05d.jpg"
        run_checked(
            [
                "ffmpeg",
                "-y",
                "-i",
                str(capture_mp4),
                "-vf",
                f"fps={args.frame_sample_fps}",
                str(frames_out),
            ],
            cwd=root,
        )

        run_checked(
            [str(scripts_dir / "prepare_gs_input_from_run.sh"), "--run", str(run_dir)],
            cwd=root,
        )

        print("\nCapture saved and prepared for training.")
        print(f"Run: {run_dir}")
        print(f"Raw video: {capture_raw_mp4}")
        print(f"Video: {capture_mp4}")
        print(f"Frames: {run_dir / 'raw' / 'images'}")
        print("\nNext:")
        print(f"{scripts_dir / 'run_handheld_prep_or_train.sh'} --run {run_dir} --mode prep-train")
        return 0
    except subprocess.CalledProcessError as exc:
        print(f"Command failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
