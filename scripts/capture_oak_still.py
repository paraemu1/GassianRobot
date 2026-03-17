#!/usr/bin/env python3
"""Capture one RGB still image from OAK camera via DepthAI."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

import cv2
import depthai as dai


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Capture one still from OAK RGB")
    p.add_argument("--output", required=True)
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--fps", type=float, default=30.0)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)

    if not dai.Device.getAllAvailableDevices():
        print("No OAK device found by DepthAI.", file=sys.stderr)
        return 1

    pipeline = dai.Pipeline()
    color = pipeline.create(dai.node.ColorCamera)
    xout = pipeline.create(dai.node.XLinkOut)
    xout.setStreamName("rgb")
    color.setResolution(dai.ColorCameraProperties.SensorResolution.THE_1080_P)
    color.setPreviewSize(args.width, args.height)
    color.setInterleaved(False)
    color.setColorOrder(dai.ColorCameraProperties.ColorOrder.BGR)
    color.setFps(float(args.fps))
    color.preview.link(xout.input)

    try:
        with dai.Device(pipeline) as device:
            q = device.getOutputQueue("rgb", maxSize=4, blocking=True)
            frame = None
            for _ in range(10):
                frame = q.get().getCvFrame()
            if frame is None:
                print("No frame available", file=sys.stderr)
                return 1
            ok = cv2.imwrite(str(out), frame)
            if not ok:
                print(f"Failed to write image: {out}", file=sys.stderr)
                return 1
    except Exception as exc:
        print(f"Capture failed: {exc!r}", file=sys.stderr)
        return 1

    print(f"Saved still: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
