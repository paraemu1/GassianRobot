#!/usr/bin/env python3
"""Inspect live timestamp alignment for RTAB-Map inputs."""

from __future__ import annotations

import argparse
import bisect
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Dict, List, Sequence

import rclpy
from rclpy.duration import Duration
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from rclpy.time import Time
from rosidl_runtime_py.utilities import get_message
from tf2_ros import Buffer, TransformListener


def topic_type(topic: str) -> str:
    result = subprocess.run(
        ["ros2", "topic", "type", topic],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"failed to resolve topic type for {topic}")

    topic_msg_type = result.stdout.strip()
    if not topic_msg_type:
        raise RuntimeError(f"empty topic type for {topic}")
    return topic_msg_type


def topic_list() -> List[str]:
    result = subprocess.run(
        ["ros2", "topic", "list"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def stamp_to_float(stamp: object) -> float:
    return float(stamp.sec) + float(stamp.nanosec) / 1_000_000_000.0


def nearest_deltas(reference: Sequence[float], target: Sequence[float]) -> List[float]:
    if not reference or not target:
        return []

    target_sorted = sorted(target)
    deltas: List[float] = []
    for stamp in reference:
        idx = bisect.bisect_left(target_sorted, stamp)
        candidates: List[float] = []
        if idx < len(target_sorted):
            candidates.append(abs(target_sorted[idx] - stamp))
        if idx > 0:
            candidates.append(abs(target_sorted[idx - 1] - stamp))
        deltas.append(min(candidates))
    return deltas


def fmt_stats(values: Sequence[float]) -> str:
    if not values:
        return "no samples"
    values_ms = [value * 1000.0 for value in values]
    return (
        f"n={len(values_ms)} min={min(values_ms):.1f}ms "
        f"median={statistics.median(values_ms):.1f}ms max={max(values_ms):.1f}ms"
    )


def within_threshold_ratio(values: Sequence[float], threshold: float) -> float:
    if not values:
        return 0.0
    return sum(1 for value in values if value <= threshold) / float(len(values))


def estimate_rate(stamps: Sequence[float]) -> str:
    if len(stamps) < 2:
        return "insufficient samples"
    span = stamps[-1] - stamps[0]
    if span <= 0:
        return "insufficient span"
    rate = (len(stamps) - 1) / span
    return f"{rate:.2f} Hz"


def sensor_qos() -> QoSProfile:
    return QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=50,
        reliability=ReliabilityPolicy.BEST_EFFORT,
    )


@dataclass
class TopicSeries:
    topic: str
    msg_type: str
    stamps: List[float] = field(default_factory=list)
    frame_ids: List[str] = field(default_factory=list)

    def add(self, msg: object) -> None:
        header = getattr(msg, "header", None)
        if header is None:
            return
        self.stamps.append(stamp_to_float(header.stamp))
        frame_id = getattr(header, "frame_id", "")
        if frame_id and frame_id not in self.frame_ids:
            self.frame_ids.append(frame_id)


class SyncInspector(Node):
    def __init__(self, topics: Dict[str, str]) -> None:
        super().__init__("check_rtabmap_sync")
        self.series: Dict[str, TopicSeries] = {}
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self, spin_thread=False)

        for label, topic in topics.items():
            msg_type = topic_type(topic)
            series = TopicSeries(topic=topic, msg_type=msg_type)
            self.series[label] = series
            self.create_subscription(
                get_message(msg_type),
                topic,
                self._build_callback(label),
                sensor_qos(),
            )

    def _build_callback(self, label: str):
        def callback(msg: object) -> None:
            self.series[label].add(msg)

        return callback


def describe_series(series: TopicSeries, publisher_count: int) -> None:
    frame_ids = ", ".join(series.frame_ids) if series.frame_ids else "<none>"
    print(
        f"{series.topic}: type={series.msg_type} publishers={publisher_count} "
        f"samples={len(series.stamps)} "
        f"rate={estimate_rate(series.stamps)} frame_ids={frame_ids}"
    )


def invalid_frame_ids(frame_ids: Sequence[str]) -> List[str]:
    return [frame_id for frame_id in frame_ids if frame_id.startswith("/")]


def main() -> int:
    parser = argparse.ArgumentParser(description="Check RTAB-Map input timestamp alignment")
    parser.add_argument("--odom-topic", default="/odom")
    parser.add_argument("--rgb-topic", default="/oak/rgb/image_raw")
    parser.add_argument("--camera-info-topic", default="/oak/rgb/camera_info")
    parser.add_argument("--depth-topic", default="/oak/stereo/image_raw")
    parser.add_argument("--odom-frame", default="odom")
    parser.add_argument("--base-frame", default="base_link")
    parser.add_argument("--map-frame", default="map")
    parser.add_argument("--duration-sec", type=float, default=10.0)
    parser.add_argument("--min-rgb-samples", type=int, default=10)
    parser.add_argument("--max-rgb-camera-info-slop-sec", type=float, default=0.05)
    parser.add_argument("--max-rgb-depth-slop-sec", type=float, default=0.10)
    parser.add_argument("--max-rgb-odom-slop-sec", type=float, default=0.10)
    parser.add_argument("--check-tf-ready", type=int, choices=(0, 1), default=1)
    parser.add_argument("--check-map-odom-tf", type=int, choices=(0, 1), default=0)
    args = parser.parse_args()

    live_topics = set(topic_list())
    missing_topics = [
        topic
        for topic in (
            args.odom_topic,
            args.rgb_topic,
            args.camera_info_topic,
            args.depth_topic,
        )
        if topic not in live_topics
    ]
    if missing_topics:
        print("Missing required live topics:", file=sys.stderr)
        for topic in missing_topics:
            print(f"  {topic}", file=sys.stderr)
        return 1

    if "/stereo/" in args.depth_topic and "/rgb/" in args.camera_info_topic:
        print(
            "Warning: stereo depth is being paired with RGB camera_info. "
            "This is only safe if the driver aligns depth to RGB before publishing.",
            file=sys.stderr,
        )
    if args.depth_topic != "/oak/depth/image_raw" and "/oak/depth/image_raw" in live_topics:
        print(
            "Note: /oak/depth/image_raw is available. Prefer it over /oak/stereo/image_raw "
            "for RTAB-Map if it is the aligned depth stream on this robot.",
            file=sys.stderr,
        )

    odom_frame = args.odom_frame.lstrip("/")
    base_frame = args.base_frame.lstrip("/")
    map_frame = args.map_frame.lstrip("/")

    rclpy.init(args=None)
    inspector = SyncInspector(
        {
            "odom": args.odom_topic,
            "rgb": args.rgb_topic,
            "camera_info": args.camera_info_topic,
            "depth": args.depth_topic,
        }
    )

    failures = 0
    try:
        deadline = time.monotonic() + args.duration_sec
        while time.monotonic() < deadline:
            rclpy.spin_once(inspector, timeout_sec=0.2)

        series = inspector.series
        publisher_counts = {
            label: inspector.count_publishers(topic_series.topic)
            for label, topic_series in series.items()
        }

        print("Topic summary:")
        for label in ("odom", "rgb", "camera_info", "depth"):
            describe_series(series[label], publisher_counts[label])
            if publisher_counts[label] == 0:
                print(
                    f"  [FAIL] {label}: no live publishers on {series[label].topic}",
                    file=sys.stderr,
                )
                failures += 1

        print("")
        print("Frame ID validation:")
        for label in ("odom", "rgb", "camera_info", "depth"):
            bad_ids = invalid_frame_ids(series[label].frame_ids)
            if bad_ids:
                print(
                    f"  [FAIL] {label}: invalid frame_ids {', '.join(bad_ids)} "
                    "(tf frame IDs must not start with '/')",
                    file=sys.stderr,
                )
                failures += 1
            else:
                print(f"  {label}: ok")

        rgb_stamps = series["rgb"].stamps
        if len(rgb_stamps) < args.min_rgb_samples:
            print(
                f"Insufficient RGB samples: got {len(rgb_stamps)}, need at least {args.min_rgb_samples}",
                file=sys.stderr,
            )
            failures += 1

        checks = {
            "rgb<->camera_info": (
                nearest_deltas(rgb_stamps, series["camera_info"].stamps),
                args.max_rgb_camera_info_slop_sec,
            ),
            "rgb<->depth": (
                nearest_deltas(rgb_stamps, series["depth"].stamps),
                args.max_rgb_depth_slop_sec,
            ),
            "rgb<->odom": (
                nearest_deltas(rgb_stamps, series["odom"].stamps),
                args.max_rgb_odom_slop_sec,
            ),
        }

        print("")
        print("Nearest-neighbor stamp deltas from RGB:")
        for label, (deltas, threshold) in checks.items():
            within_ratio = within_threshold_ratio(deltas, threshold)
            print(
                f"  {label}: {fmt_stats(deltas)} "
                f"within_threshold={within_ratio * 100.0:.1f}% "
                f"threshold={threshold * 1000.0:.1f}ms"
            )
            if not deltas:
                print(f"  [FAIL] {label}: no comparable samples", file=sys.stderr)
                failures += 1
                continue
            median_delta = statistics.median(deltas)
            if median_delta > threshold:
                print(
                    f"  [FAIL] {label}: median delta {median_delta * 1000.0:.1f}ms exceeds threshold",
                    file=sys.stderr,
                )
                failures += 1

        if args.check_tf_ready:
            print("")
            print("TF readiness:")
            odom_ready = inspector.tf_buffer.can_transform(
                odom_frame,
                base_frame,
                Time(),
                timeout=Duration(seconds=0.2),
            )
            print(f"  {odom_frame} <- {base_frame}: {'ready' if odom_ready else 'missing'}")
            if not odom_ready:
                print(
                    f"  [FAIL] missing transform {odom_frame} <- {base_frame}",
                    file=sys.stderr,
                )
                failures += 1

            if args.check_map_odom_tf:
                map_ready = inspector.tf_buffer.can_transform(
                    map_frame,
                    odom_frame,
                    Time(),
                    timeout=Duration(seconds=0.2),
                )
                print(f"  {map_frame} <- {odom_frame}: {'ready' if map_ready else 'missing'}")
                if not map_ready:
                    print(
                        f"  [FAIL] missing transform {map_frame} <- {odom_frame}",
                        file=sys.stderr,
                    )
                    failures += 1
    finally:
        inspector.destroy_node()
        rclpy.shutdown()

    if failures:
        return 1

    print("")
    print("Sync check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
