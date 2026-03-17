#!/usr/bin/env python3
"""One-command OAK camera health check.

Checks:
1. DepthAI can see at least one device.
2. Device boots and reports connected cameras.
3. One RGB frame is captured and saved.
4. One depth frame is captured and saved with valid depth pixels.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import cv2
import depthai as dai
import numpy as np


def log(msg: str) -> None:
    print(msg, flush=True)


def fail(msg: str) -> int:
    print(f"[FAIL] {msg}", file=sys.stderr, flush=True)
    return 1


def colorize_depth(depth_mm: np.ndarray) -> np.ndarray:
    valid = depth_mm > 0
    if not np.any(valid):
        return np.zeros((depth_mm.shape[0], depth_mm.shape[1], 3), dtype=np.uint8)

    min_d = int(depth_mm[valid].min())
    max_d = int(depth_mm[valid].max())
    if max_d <= min_d:
        max_d = min_d + 1

    scaled = np.clip((depth_mm.astype(np.float32) - min_d) * (255.0 / (max_d - min_d)), 0, 255)
    scaled[~valid] = 0
    depth_u8 = scaled.astype(np.uint8)
    return cv2.applyColorMap(depth_u8, cv2.COLORMAP_TURBO)


def main() -> int:
    parser = argparse.ArgumentParser(description="OAK camera health check")
    parser.add_argument(
        "--out-dir",
        default="runs/camera_health",
        help="Directory to store captured artifacts (default: runs/camera_health)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned checks without connecting to hardware.",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")

    rgb_path = out_dir / f"oak_rgb_{ts}.jpg"
    depth_raw_path = out_dir / f"oak_depth_{ts}.png"
    depth_color_path = out_dir / f"oak_depth_color_{ts}.jpg"

    if args.dry_run:
        log("[INFO] Dry run mode; no camera access will be attempted.")
        log(f"[INFO] Would write RGB image to: {rgb_path}")
        log(f"[INFO] Would write depth raw image to: {depth_raw_path}")
        log(f"[INFO] Would write depth color image to: {depth_color_path}")
        return 0

    log("[INFO] Searching for OAK device...")
    devices = dai.Device.getAllAvailableDevices()
    if not devices:
        return fail("No OAK device found by DepthAI.")

    info = devices[0]
    log(f"[PASS] Device discovered: mxid={info.getMxId()} name={info.name} state={info.state}")

    pipeline = dai.Pipeline()

    color = pipeline.create(dai.node.ColorCamera)
    color_xout = pipeline.create(dai.node.XLinkOut)
    color_xout.setStreamName("rgb")
    color.setResolution(dai.ColorCameraProperties.SensorResolution.THE_1080_P)
    color.setPreviewSize(1280, 720)
    color.setInterleaved(False)
    color.setColorOrder(dai.ColorCameraProperties.ColorOrder.BGR)
    color.preview.link(color_xout.input)

    mono_l = pipeline.create(dai.node.MonoCamera)
    mono_r = pipeline.create(dai.node.MonoCamera)
    stereo = pipeline.create(dai.node.StereoDepth)
    depth_xout = pipeline.create(dai.node.XLinkOut)
    depth_xout.setStreamName("depth")

    mono_l.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)
    mono_r.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)
    mono_l.setBoardSocket(dai.CameraBoardSocket.CAM_B)
    mono_r.setBoardSocket(dai.CameraBoardSocket.CAM_C)
    mono_l.out.link(stereo.left)
    mono_r.out.link(stereo.right)
    stereo.depth.link(depth_xout.input)

    try:
        with dai.Device(pipeline, info) as device:
            usb_speed = device.getUsbSpeed()
            features = device.getConnectedCameraFeatures()
            log(f"[PASS] Device booted (USB speed: {usb_speed})")
            log(f"[INFO] Connected sensors: {len(features)}")
            for f in features:
                log(
                    f"       socket={f.socket} sensor={f.sensorName} "
                    f"resolution={f.width}x{f.height} autofocus={getattr(f, 'hasAutofocus', False)}"
                )

            q_rgb = device.getOutputQueue("rgb", maxSize=4, blocking=True)
            q_depth = device.getOutputQueue("depth", maxSize=4, blocking=True)

            rgb_frame = None
            for _ in range(20):
                rgb_frame = q_rgb.get().getCvFrame()
            if rgb_frame is None:
                return fail("No RGB frame received.")

            depth_frame = q_depth.get().getFrame()
            if depth_frame is None:
                return fail("No depth frame received.")

            valid_depth = int((depth_frame > 0).sum())
            if valid_depth == 0:
                return fail("Depth frame received but has zero valid depth pixels.")

            if not cv2.imwrite(str(rgb_path), rgb_frame):
                return fail(f"Failed to write RGB image: {rgb_path}")
            if not cv2.imwrite(str(depth_raw_path), depth_frame):
                return fail(f"Failed to write depth raw image: {depth_raw_path}")

            depth_color = colorize_depth(depth_frame)
            if not cv2.imwrite(str(depth_color_path), depth_color):
                return fail(f"Failed to write colorized depth image: {depth_color_path}")

            min_d = int(depth_frame[depth_frame > 0].min())
            max_d = int(depth_frame.max())
            log(f"[PASS] RGB frame captured: {rgb_frame.shape[1]}x{rgb_frame.shape[0]}")
            log(
                "[PASS] Depth frame captured: "
                f"{depth_frame.shape[1]}x{depth_frame.shape[0]}, "
                f"valid_pixels={valid_depth}, min_mm={min_d}, max_mm={max_d}"
            )

    except Exception as exc:  # pragma: no cover
        return fail(f"DepthAI pipeline failed: {exc!r}")

    log("[PASS] Camera health check complete")
    log(f"[INFO] RGB image: {rgb_path}")
    log(f"[INFO] Depth raw image: {depth_raw_path}")
    log(f"[INFO] Depth color image: {depth_color_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
