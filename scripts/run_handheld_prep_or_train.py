#!/usr/bin/env python3
"""Prepare and/or train from a manual handheld OAK test run."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


MARKER_FILENAME = "HANDHELD_CAMERA_MOTION_TEST.txt"


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_checked(cmd: list[str], cwd: Path) -> None:
    print("$ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=str(cwd), check=True)


def latest_labeled_run(runs_dir: Path) -> Path | None:
    markers = sorted(
        runs_dir.glob(f"*/{MARKER_FILENAME}"),
        key=lambda p: p.parent.stat().st_mtime,
    )
    if not markers:
        return None
    return markers[-1].parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prep and/or train from handheld test run")
    parser.add_argument(
        "--run",
        default="",
        help="Run directory path. If omitted, uses newest labeled handheld test run.",
    )
    parser.add_argument(
        "--mode",
        choices=["prep", "train", "prep-train"],
        default="prep-train",
        help="Which stages to run (default: prep-train)",
    )
    parser.add_argument("--downscale", type=int, default=2, help="Downscale factor for ns-process-data")
    parser.add_argument(
        "--blur-threshold",
        type=float,
        default=4.0,
        help="If >0 and mode includes prep, apply blur filtering to raw/capture.mp4 before prep (default: 4.0).",
    )
    parser.add_argument("--host", action="store_true", help="Run training on host instead of Docker")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    scripts_dir = root / "scripts"

    if args.run:
        run_dir = Path(args.run).expanduser().resolve()
    else:
        detected = latest_labeled_run(root / "runs")
        if detected is None:
            print(
                "No labeled handheld test run found. "
                "Run manual_handheld_oak_capture_test.sh first or pass --run.",
                file=sys.stderr,
            )
            return 1
        run_dir = detected
        print(f"Using latest labeled handheld run: {run_dir}")

    if not run_dir.is_dir():
        print(f"Run directory not found: {run_dir}", file=sys.stderr)
        return 1

    try:
        if args.mode in ("prep", "prep-train"):
            if args.blur_threshold > 0:
                capture_raw = run_dir / "raw" / "capture_raw.mp4"
                capture = run_dir / "raw" / "capture.mp4"
                filter_input = capture_raw if capture_raw.is_file() else capture
                if not filter_input.is_file():
                    print(
                        f"Could not find capture video for blur filtering in {run_dir / 'raw'}",
                        file=sys.stderr,
                    )
                    return 1

                if filter_input.resolve() == capture.resolve():
                    filter_output = run_dir / "raw" / "capture_filtered_tmp.mp4"
                else:
                    filter_output = capture

                filter_cmd = [
                    str(scripts_dir / "filter_blurry_video_frames.sh"),
                    "--input",
                    str(filter_input),
                    "--output",
                    str(filter_output),
                    "--threshold",
                    str(args.blur_threshold),
                    "--report-csv",
                    str(run_dir / "logs" / "blur_filter_report.csv"),
                ]
                run_checked(filter_cmd, cwd=root)

                if filter_output.name == "capture_filtered_tmp.mp4":
                    filter_output.replace(capture)

            run_checked(
                [str(scripts_dir / "prepare_gs_input_from_run.sh"), "--run", str(run_dir)],
                cwd=root,
            )

        if args.mode in ("train", "prep-train"):
            cmd = [
                str(scripts_dir / "process_train_export.sh"),
                "--run",
                str(run_dir),
                "--from-run-env",
                "--downscale",
                str(args.downscale),
            ]
            if args.host:
                cmd.append("--host")
            run_checked(cmd, cwd=root)

        print("\nDone.")
        print(f"Run: {run_dir}")
        if args.mode in ("train", "prep-train"):
            print(f"Export: {run_dir / 'exports' / 'splat'}")
        return 0
    except subprocess.CalledProcessError as exc:
        print(f"Command failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
