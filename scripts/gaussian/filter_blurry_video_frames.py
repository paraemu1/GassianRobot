#!/usr/bin/env python3
"""Filter blurry frames from a video using Laplacian variance."""

from __future__ import annotations

import argparse
import csv
import shutil
import sys
from pathlib import Path

import cv2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Filter blurry frames from video")
    parser.add_argument("--input", required=True, help="Input video path")
    parser.add_argument("--output", required=True, help="Output video path")
    parser.add_argument(
        "--threshold",
        type=float,
        default=4.0,
        help="Laplacian variance threshold. Lower keeps more frames. Use <=0 to disable filtering.",
    )
    parser.add_argument(
        "--report-csv",
        default="",
        help="Optional CSV report path (frame_idx, blur_score, kept)",
    )
    return parser.parse_args()


def blur_score(frame_bgr) -> float:
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    if not input_path.is_file():
        print(f"Input video not found: {input_path}", file=sys.stderr)
        return 1

    output_path.parent.mkdir(parents=True, exist_ok=True)

    if args.threshold <= 0:
        if input_path == output_path:
            print("Filtering disabled and input==output; no-op.")
            return 0
        shutil.copy2(input_path, output_path)
        print(f"Filtering disabled (threshold={args.threshold}); copied input to output.")
        return 0

    cap = cv2.VideoCapture(str(input_path))
    if not cap.isOpened():
        print(f"Failed to open input video: {input_path}", file=sys.stderr)
        return 1

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    if width <= 0 or height <= 0:
        print("Invalid input video dimensions.", file=sys.stderr)
        cap.release()
        return 1

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(output_path), fourcc, float(fps), (width, height))
    if not writer.isOpened():
        print(f"Failed to open output video writer: {output_path}", file=sys.stderr)
        cap.release()
        return 1

    report_writer = None
    report_file = None
    if args.report_csv:
        report_path = Path(args.report_csv).expanduser().resolve()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_file = report_path.open("w", newline="", encoding="utf-8")
        report_writer = csv.writer(report_file)
        report_writer.writerow(["frame_idx", "blur_score", "kept"])

    total = 0
    kept = 0
    score_sum = 0.0

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            total += 1
            score = blur_score(frame)
            score_sum += score
            keep = score >= args.threshold
            if keep:
                writer.write(frame)
                kept += 1
            if report_writer is not None:
                report_writer.writerow([total - 1, f"{score:.6f}", int(keep)])
    finally:
        cap.release()
        writer.release()
        if report_file is not None:
            report_file.close()

    if total == 0:
        print("Input video had zero frames.", file=sys.stderr)
        return 1

    if kept == 0:
        print(
            "All frames were filtered out. Lower --threshold and try again.",
            file=sys.stderr,
        )
        return 1

    keep_ratio = kept / total
    avg_score = score_sum / total
    print(
        f"Filtered video written: {output_path}\n"
        f"Total frames: {total}\n"
        f"Kept frames: {kept}\n"
        f"Dropped frames: {total - kept}\n"
        f"Keep ratio: {keep_ratio:.3f}\n"
        f"Threshold: {args.threshold}\n"
        f"Average blur score: {avg_score:.3f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
