#!/usr/bin/env python3
"""Capture one RGB still image from OAK camera via DepthAI."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Optional

import cv2
import depthai as dai
import numpy as np

try:
    import rclpy
    from rclpy.node import Node
    from sensor_msgs.msg import Image
except ImportError:  # pragma: no cover - host fallback without ROS deps
    rclpy = None
    Node = object
    Image = None


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Capture one still from OAK RGB")
    p.add_argument("--output", required=True)
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--fps", type=float, default=30.0)
    p.add_argument("--ros-topic", default="/oak/rgb/image_raw")
    p.add_argument("--ros-timeout-sec", type=float, default=5.0)
    return p.parse_args()


class RosImageGrabber(Node):
    def __init__(self, topic: str) -> None:
        super().__init__("capture_oak_still")
        self.image: Optional[Image] = None
        self.create_subscription(Image, topic, self._cb, 10)

    def _cb(self, msg: Image) -> None:
        self.image = msg


def ros_image_to_bgr(msg: Image) -> np.ndarray:
    if msg.encoding not in {"bgr8", "rgb8", "mono8"}:
        raise ValueError(f"Unsupported ROS image encoding: {msg.encoding}")

    channels = 1 if msg.encoding == "mono8" else 3
    frame = np.frombuffer(msg.data, dtype=np.uint8)
    frame = frame.reshape((msg.height, msg.width, channels)) if channels > 1 else frame.reshape((msg.height, msg.width))

    if msg.encoding == "rgb8":
        return cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
    if msg.encoding == "mono8":
        return cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
    return frame


def capture_from_ros(topic: str, timeout_sec: float) -> np.ndarray:
    if rclpy is None or Image is None:
        raise RuntimeError("ROS Python dependencies are not available")

    rclpy.init()
    node = RosImageGrabber(topic)
    deadline_ns = node.get_clock().now().nanoseconds + int(timeout_sec * 1e9)

    try:
        while rclpy.ok() and node.image is None and node.get_clock().now().nanoseconds < deadline_ns:
            rclpy.spin_once(node, timeout_sec=0.2)
        if node.image is None:
            raise TimeoutError(f"Timed out waiting for ROS image on {topic}")
        return ros_image_to_bgr(node.image)
    finally:
        node.destroy_node()
        rclpy.shutdown()


def main() -> int:
    args = parse_args()
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)

    frame = None

    if rclpy is not None:
        try:
            frame = capture_from_ros(args.ros_topic, args.ros_timeout_sec)
        except Exception as exc:
            print(f"ROS image capture unavailable: {exc!r}", file=sys.stderr)

    if frame is None:
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
                for _ in range(10):
                    frame = q.get().getCvFrame()
                if frame is None:
                    print("No frame available", file=sys.stderr)
                    return 1
        except Exception as exc:
            print(f"Capture failed: {exc!r}", file=sys.stderr)
            return 1

    ok = cv2.imwrite(str(out), frame)
    if not ok:
        print(f"Failed to write image: {out}", file=sys.stderr)
        return 1

    print(f"Saved still: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
