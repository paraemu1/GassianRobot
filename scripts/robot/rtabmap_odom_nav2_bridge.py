#!/usr/bin/env python3
"""Relay RTAB-Map odometry for Nav2 and publish matching odom->base_link TF."""

from __future__ import annotations

import argparse
import math

import rclpy
from geometry_msgs.msg import TransformStamped
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from tf2_ros import TransformBroadcaster


def best_effort_qos() -> QoSProfile:
    return QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=50,
        reliability=ReliabilityPolicy.BEST_EFFORT,
    )


def reliable_qos() -> QoSProfile:
    return QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=50,
        reliability=ReliabilityPolicy.RELIABLE,
    )


def normalize_frame_id(frame_id: str) -> str:
    return frame_id.lstrip("/")


def normalize_orientation(msg: Odometry) -> None:
    orientation = msg.pose.pose.orientation
    norm = math.sqrt(
        orientation.x * orientation.x
        + orientation.y * orientation.y
        + orientation.z * orientation.z
        + orientation.w * orientation.w
    )
    if norm <= 1e-9:
        orientation.x = 0.0
        orientation.y = 0.0
        orientation.z = 0.0
        orientation.w = 1.0
        return

    orientation.x /= norm
    orientation.y /= norm
    orientation.z /= norm
    orientation.w /= norm


class OdomBridge(Node):
    def __init__(
        self,
        source_topic: str,
        relay_topic: str,
        default_odom_frame: str,
        default_base_frame: str,
    ) -> None:
        super().__init__("rtabmap_odom_nav2_bridge")
        self.relay_topic = relay_topic
        self.default_odom_frame = normalize_frame_id(default_odom_frame)
        self.default_base_frame = normalize_frame_id(default_base_frame)
        self.tf_broadcaster = TransformBroadcaster(self)
        self.odom_publisher = self.create_publisher(Odometry, relay_topic, reliable_qos())
        self.create_subscription(Odometry, source_topic, self._on_odom, best_effort_qos())
        self._logged_first_message = False

    def _on_odom(self, msg: Odometry) -> None:
        relay_msg = Odometry()
        relay_msg.header = msg.header
        relay_msg.header.frame_id = normalize_frame_id(msg.header.frame_id) or self.default_odom_frame
        relay_msg.child_frame_id = normalize_frame_id(msg.child_frame_id) or self.default_base_frame
        relay_msg.pose = msg.pose
        relay_msg.twist = msg.twist
        normalize_orientation(relay_msg)

        self.odom_publisher.publish(relay_msg)

        transform = TransformStamped()
        transform.header = relay_msg.header
        transform.child_frame_id = relay_msg.child_frame_id
        transform.transform.translation.x = relay_msg.pose.pose.position.x
        transform.transform.translation.y = relay_msg.pose.pose.position.y
        transform.transform.translation.z = relay_msg.pose.pose.position.z
        transform.transform.rotation = relay_msg.pose.pose.orientation
        self.tf_broadcaster.sendTransform(transform)

        if not self._logged_first_message:
            self.get_logger().info(
                f"Relaying {relay_msg.header.frame_id} -> {relay_msg.child_frame_id} "
                f"onto {self.relay_topic} and /tf"
            )
            self._logged_first_message = True


def main() -> int:
    parser = argparse.ArgumentParser(description="Relay RTAB-Map odometry for Nav2")
    parser.add_argument("--source-topic", default="/odom")
    parser.add_argument("--relay-topic", default="/odom_nav2")
    parser.add_argument("--default-odom-frame", default="odom")
    parser.add_argument("--default-base-frame", default="base_link")
    args = parser.parse_args()

    rclpy.init(args=None)
    node = OdomBridge(
        source_topic=args.source_topic,
        relay_topic=args.relay_topic,
        default_odom_frame=args.default_odom_frame,
        default_base_frame=args.default_base_frame,
    )
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
