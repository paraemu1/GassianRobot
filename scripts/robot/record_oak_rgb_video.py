#!/usr/bin/env python3
"""Record RGB video directly from an OAK camera using DepthAI."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import cv2
import depthai as dai


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Record OAK RGB video")
    parser.add_argument("--output", required=True, help="Output MP4 path")
    parser.add_argument("--duration", type=float, default=20.0, help="Duration in seconds")
    parser.add_argument("--width", type=int, default=1280, help="Output width")
    parser.add_argument("--height", type=int, default=720, help="Output height")
    parser.add_argument("--fps", type=float, default=30.0, help="Capture FPS")
    parser.add_argument(
        "--sensor-resolution",
        choices=["1080p", "4k", "12mp"],
        default="1080p",
        help="Color sensor resolution",
    )
    return parser.parse_args()


def resolution_from_name(name: str) -> dai.ColorCameraProperties.SensorResolution:
    if name == "4k":
        return dai.ColorCameraProperties.SensorResolution.THE_4_K
    if name == "12mp":
        return dai.ColorCameraProperties.SensorResolution.THE_12_MP
    return dai.ColorCameraProperties.SensorResolution.THE_1080_P


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    if not dai.Device.getAllAvailableDevices():
        print("No OAK device found by DepthAI.", file=sys.stderr)
        return 1

    pipeline = dai.Pipeline()
    color = pipeline.create(dai.node.ColorCamera)
    xout = pipeline.create(dai.node.XLinkOut)
    xout.setStreamName("rgb")

    color.setResolution(resolution_from_name(args.sensor_resolution))
    color.setPreviewSize(args.width, args.height)
    color.setInterleaved(False)
    color.setColorOrder(dai.ColorCameraProperties.ColorOrder.BGR)
    color.setFps(float(args.fps))
    color.preview.link(xout.input)

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(output), fourcc, float(args.fps), (int(args.width), int(args.height)))
    if not writer.isOpened():
        print(f"Failed to open video writer: {output}", file=sys.stderr)
        return 1

    frames = 0
    try:
        with dai.Device(pipeline) as device:
            q_rgb = device.getOutputQueue("rgb", maxSize=8, blocking=True)
            start = time.monotonic()
            while (time.monotonic() - start) < float(args.duration):
                frame = q_rgb.get().getCvFrame()
                if frame is None:
                    continue
                writer.write(frame)
                frames += 1
    except Exception as exc:
        print(f"DepthAI capture failed: {exc!r}", file=sys.stderr)
        return 1
    finally:
        writer.release()

    if frames == 0:
        print("No RGB frames captured from OAK.", file=sys.stderr)
        return 1

    print(
        f"Recorded {frames} frames to {output} "
        f"({args.width}x{args.height} @ {args.fps} fps, {args.duration}s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
