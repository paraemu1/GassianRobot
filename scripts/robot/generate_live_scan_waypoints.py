#!/usr/bin/env python3
import argparse
import math
import os
import sys
from typing import Iterable, List, Tuple

import rclpy
from geometry_msgs.msg import PoseWithCovarianceStamped
from rclpy.node import Node
from rclpy.time import Time
from tf2_ros import Buffer, TransformException, TransformListener


class PoseProbe(Node):
    def __init__(self, pose_topic: str) -> None:
        super().__init__("generate_live_scan_waypoints")
        self._msg = None
        self._pose_topic = pose_topic
        self.create_subscription(PoseWithCovarianceStamped, pose_topic, self._cb, 10)
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self, spin_thread=False)

    def _cb(self, msg: PoseWithCovarianceStamped) -> None:
        self._msg = msg

    @property
    def message(self):
        return self._msg

    @property
    def pose_topic(self) -> str:
        return self._pose_topic


def quat_to_yaw(z: float, w: float) -> float:
    return math.atan2(2.0 * w * z, 1.0 - 2.0 * z * z)


def yaw_to_quat(yaw: float) -> Tuple[float, float]:
    return math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def build_pattern(forward_step: float, lane_width: float) -> List[Tuple[float, float]]:
    return [
        (forward_step, 0.0),
        (forward_step * 2.0, 0.0),
        (forward_step * 2.0, lane_width),
        (forward_step, lane_width),
    ]


def append_if_new(points: List[Tuple[float, float]], point: Tuple[float, float]) -> None:
    if points and abs(points[-1][0] - point[0]) < 1e-9 and abs(points[-1][1] - point[1]) < 1e-9:
        return
    points.append(point)


def build_serpentine_pattern(
    forward_step: float,
    lane_width: float,
    cols: int,
    rows: int,
    return_to_entry: bool,
) -> List[Tuple[float, float]]:
    if cols < 1 or rows < 1:
        raise ValueError("rows and cols must both be >= 1")

    points: List[Tuple[float, float]] = []
    entry_x = forward_step

    for row in range(rows):
        y = row * lane_width
        x_values = [(col + 1) * forward_step for col in range(cols)]
        if row % 2 == 1:
            x_values.reverse()
        for x in x_values:
            append_if_new(points, (x, y))

    if return_to_entry and points:
        current_x, current_y = points[-1]
        if abs(current_x - entry_x) > 1e-9:
            append_if_new(points, (entry_x, current_y))

        for row in range(rows - 2, -1, -1):
            append_if_new(points, (entry_x, row * lane_width))

    return points


def transform_points(
    base_x: float,
    base_y: float,
    base_yaw: float,
    points: Iterable[Tuple[float, float]],
) -> List[Tuple[float, float]]:
    cos_yaw = math.cos(base_yaw)
    sin_yaw = math.sin(base_yaw)
    transformed = []
    for dx, dy in points:
        x = base_x + cos_yaw * dx - sin_yaw * dy
        y = base_y + sin_yaw * dx + cos_yaw * dy
        transformed.append((x, y))
    return transformed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate short live RTAB-Map scan waypoints from the current map-frame pose."
    )
    parser.add_argument("--output", required=True, help="Output TSV path.")
    parser.add_argument("--pose-topic", default=os.environ.get("POSE_TOPIC", "/rtabmap/localization_pose"))
    parser.add_argument("--map-frame", default=os.environ.get("MAP_FRAME", "map"))
    parser.add_argument("--base-frame", default=os.environ.get("BASE_FRAME", "base_link"))
    parser.add_argument("--timeout-sec", type=float, default=float(os.environ.get("POSE_TIMEOUT_SEC", "10")))
    parser.add_argument(
        "--topic-timeout-sec",
        type=float,
        default=float(os.environ.get("POSE_TOPIC_TIMEOUT_SEC", "2")),
        help="How long to wait on the pose topic before falling back to TF.",
    )
    parser.add_argument(
        "--forward-step",
        type=float,
        default=float(os.environ.get("LIVE_WAYPOINT_FORWARD_STEP_M", "0.18")),
    )
    parser.add_argument(
        "--lane-width",
        type=float,
        default=float(os.environ.get("LIVE_WAYPOINT_LANE_WIDTH_M", "0.18")),
    )
    parser.add_argument(
        "--pattern",
        choices=("box", "serpentine"),
        default=os.environ.get("LIVE_WAYPOINT_PATTERN", "box"),
    )
    parser.add_argument(
        "--cols",
        type=int,
        default=int(os.environ.get("LIVE_WAYPOINT_COLS", "4")),
    )
    parser.add_argument(
        "--rows",
        type=int,
        default=int(os.environ.get("LIVE_WAYPOINT_ROWS", "4")),
    )
    parser.add_argument(
        "--return-to-entry",
        type=int,
        choices=(0, 1),
        default=int(os.environ.get("LIVE_WAYPOINT_RETURN_TO_ENTRY", "1")),
    )
    parser.add_argument("--hold-sec", type=float, default=float(os.environ.get("LIVE_WAYPOINT_HOLD_SEC", "4")))
    return parser.parse_args()


def lookup_pose_from_tf(node: PoseProbe, map_frame: str, base_frame: str) -> Tuple[float, float, float]:
    transform = node.tf_buffer.lookup_transform(map_frame, base_frame, Time())
    translation = transform.transform.translation
    rotation = transform.transform.rotation
    return translation.x, translation.y, quat_to_yaw(rotation.z, rotation.w)


def lookup_pose_from_topic(node: PoseProbe) -> Tuple[float, float, float]:
    pose = node.message.pose.pose
    return pose.position.x, pose.position.y, quat_to_yaw(pose.orientation.z, pose.orientation.w)


def main() -> int:
    args = parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)

    rclpy.init()
    node = PoseProbe(args.pose_topic)
    overall_deadline_ns = node.get_clock().now().nanoseconds + int(args.timeout_sec * 1e9)
    topic_deadline_ns = node.get_clock().now().nanoseconds + int(args.topic_timeout_sec * 1e9)

    source = None
    base_x = None
    base_y = None
    base_yaw = None
    last_tf_error = None

    try:
        while rclpy.ok() and node.get_clock().now().nanoseconds < overall_deadline_ns:
            rclpy.spin_once(node, timeout_sec=0.2)

            # Prefer live TF because it is what Nav2 already consumes and it stayed reliable
            # even when /rtabmap/localization_pose had no samples.
            try:
                base_x, base_y, base_yaw = lookup_pose_from_tf(node, args.map_frame, args.base_frame)
                source = f"tf:{args.map_frame}->{args.base_frame}"
                break
            except TransformException as exc:
                last_tf_error = exc

            if node.message is not None:
                base_x, base_y, base_yaw = lookup_pose_from_topic(node)
                source = f"topic:{node.pose_topic}"
                break

            if node.get_clock().now().nanoseconds >= topic_deadline_ns and last_tf_error is not None:
                # Keep waiting on TF for the rest of the total timeout; by this point the topic
                # has already had its chance and TF is the only useful remaining source.
                continue

        if source is None:
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

        qz, qw = yaw_to_quat(base_yaw)
        if args.pattern == "serpentine":
            points = build_serpentine_pattern(
                args.forward_step,
                args.lane_width,
                args.cols,
                args.rows,
                bool(args.return_to_entry),
            )
        else:
            points = build_pattern(args.forward_step, args.lane_width)
        transformed = transform_points(base_x, base_y, base_yaw, points)

        with open(args.output, "w", encoding="ascii") as handle:
            handle.write("# x y qz qw hold_sec\n")
            for x, y in transformed:
                handle.write(f"{x:.4f} {y:.4f} {qz:.6f} {qw:.6f} {args.hold_sec:g}\n")

        print(f"pose_source={source}")
        print(f"pattern={args.pattern}")
        print(f"waypoint_count={len(transformed)}")
        print(f"base_x={base_x:.4f}")
        print(f"base_y={base_y:.4f}")
        print(f"base_yaw_rad={base_yaw:.4f}")
        print(f"output={args.output}")
        return 0
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
