#!/usr/bin/env python3
import argparse
import math
import os
import sys
from typing import Optional, Tuple

import rclpy
from geometry_msgs.msg import PoseWithCovarianceStamped
from rclpy.node import Node
from rclpy.time import Time
from tf2_ros import Buffer, TransformException, TransformListener


class PoseProbe(Node):
    def __init__(self, pose_topic: str) -> None:
        super().__init__("get_robot_map_pose")
        self._msg: Optional[PoseWithCovarianceStamped] = None
        self._pose_topic = pose_topic
        self.create_subscription(PoseWithCovarianceStamped, pose_topic, self._cb, 10)
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self, spin_thread=False)

    def _cb(self, msg: PoseWithCovarianceStamped) -> None:
        self._msg = msg

    @property
    def message(self) -> Optional[PoseWithCovarianceStamped]:
        return self._msg

    @property
    def pose_topic(self) -> str:
        return self._pose_topic


def quat_to_yaw(z: float, w: float) -> float:
    return math.atan2(2.0 * w * z, 1.0 - 2.0 * z * z)


def lookup_pose_from_tf(node: PoseProbe, map_frame: str, base_frame: str) -> Tuple[float, float, float]:
    transform = node.tf_buffer.lookup_transform(map_frame, base_frame, Time())
    translation = transform.transform.translation
    rotation = transform.transform.rotation
    return translation.x, translation.y, quat_to_yaw(rotation.z, rotation.w)


def lookup_pose_from_topic(node: PoseProbe) -> Tuple[float, float, float]:
    pose = node.message.pose.pose
    return pose.position.x, pose.position.y, quat_to_yaw(pose.orientation.z, pose.orientation.w)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Print the current robot pose in the map frame.")
    parser.add_argument("--pose-topic", default=os.environ.get("POSE_TOPIC", "/rtabmap/localization_pose"))
    parser.add_argument("--map-frame", default=os.environ.get("MAP_FRAME", "map"))
    parser.add_argument("--base-frame", default=os.environ.get("BASE_FRAME", "base_link"))
    parser.add_argument("--timeout-sec", type=float, default=float(os.environ.get("POSE_TIMEOUT_SEC", "10")))
    parser.add_argument(
        "--topic-timeout-sec",
        type=float,
        default=float(os.environ.get("POSE_TOPIC_TIMEOUT_SEC", "2")),
        help="How long to wait on the pose topic before only waiting on TF.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rclpy.init()
    node = PoseProbe(args.pose_topic)
    overall_deadline_ns = node.get_clock().now().nanoseconds + int(args.timeout_sec * 1e9)
    topic_deadline_ns = node.get_clock().now().nanoseconds + int(args.topic_timeout_sec * 1e9)

    source = None
    pose = None
    last_tf_error = None

    try:
        while rclpy.ok() and node.get_clock().now().nanoseconds < overall_deadline_ns:
            rclpy.spin_once(node, timeout_sec=0.2)

            try:
                pose = lookup_pose_from_tf(node, args.map_frame, args.base_frame)
                source = f"tf:{args.map_frame}->{args.base_frame}"
                break
            except TransformException as exc:
                last_tf_error = exc

            if node.message is not None:
                pose = lookup_pose_from_topic(node)
                source = f"topic:{node.pose_topic}"
                break

            if node.get_clock().now().nanoseconds >= topic_deadline_ns and last_tf_error is not None:
                continue

        if pose is None or source is None:
            if last_tf_error is not None:
                print(
                    f"Timed out waiting for pose from TF {args.map_frame}->{args.base_frame} "
                    f"or topic {args.pose_topic}: {last_tf_error}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"Timed out waiting for pose from TF {args.map_frame}->{args.base_frame} "
                    f"or topic {args.pose_topic}",
                    file=sys.stderr,
                )
            return 1

        x, y, yaw = pose
        print(f"{x:.6f} {y:.6f} {yaw:.6f} {source}")
        return 0
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
