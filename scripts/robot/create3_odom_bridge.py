#!/usr/bin/env python3
"""Bridge Create 3 odometry over UDP between ROS domains."""

from __future__ import annotations

import argparse
import json
import socket
import sys
from typing import Optional

import rclpy
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy


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


def odom_to_dict(msg: Odometry) -> dict:
    return {
        "header": {
            "stamp": {
                "sec": int(msg.header.stamp.sec),
                "nanosec": int(msg.header.stamp.nanosec),
            },
            "frame_id": msg.header.frame_id,
        },
        "child_frame_id": msg.child_frame_id,
        "pose": {
            "position": {
                "x": msg.pose.pose.position.x,
                "y": msg.pose.pose.position.y,
                "z": msg.pose.pose.position.z,
            },
            "orientation": {
                "x": msg.pose.pose.orientation.x,
                "y": msg.pose.pose.orientation.y,
                "z": msg.pose.pose.orientation.z,
                "w": msg.pose.pose.orientation.w,
            },
            "covariance": list(msg.pose.covariance),
        },
        "twist": {
            "linear": {
                "x": msg.twist.twist.linear.x,
                "y": msg.twist.twist.linear.y,
                "z": msg.twist.twist.linear.z,
            },
            "angular": {
                "x": msg.twist.twist.angular.x,
                "y": msg.twist.twist.angular.y,
                "z": msg.twist.twist.angular.z,
            },
            "covariance": list(msg.twist.covariance),
        },
    }


def fill_covariance(values: list[float], default_length: int = 36) -> list[float]:
    covariance = [float(value) for value in values[:default_length]]
    if len(covariance) < default_length:
        covariance.extend([0.0] * (default_length - len(covariance)))
    return covariance


def dict_to_odom(payload: dict) -> Odometry:
    msg = Odometry()

    header = payload.get("header", {})
    stamp = header.get("stamp", {})
    msg.header.stamp.sec = int(stamp.get("sec", 0))
    msg.header.stamp.nanosec = int(stamp.get("nanosec", 0))
    msg.header.frame_id = str(header.get("frame_id", ""))
    msg.child_frame_id = str(payload.get("child_frame_id", ""))

    pose = payload.get("pose", {})
    position = pose.get("position", {})
    orientation = pose.get("orientation", {})
    msg.pose.pose.position.x = float(position.get("x", 0.0))
    msg.pose.pose.position.y = float(position.get("y", 0.0))
    msg.pose.pose.position.z = float(position.get("z", 0.0))
    msg.pose.pose.orientation.x = float(orientation.get("x", 0.0))
    msg.pose.pose.orientation.y = float(orientation.get("y", 0.0))
    msg.pose.pose.orientation.z = float(orientation.get("z", 0.0))
    msg.pose.pose.orientation.w = float(orientation.get("w", 1.0))
    msg.pose.covariance = fill_covariance(pose.get("covariance", []))

    twist = payload.get("twist", {})
    linear = twist.get("linear", {})
    angular = twist.get("angular", {})
    msg.twist.twist.linear.x = float(linear.get("x", 0.0))
    msg.twist.twist.linear.y = float(linear.get("y", 0.0))
    msg.twist.twist.linear.z = float(linear.get("z", 0.0))
    msg.twist.twist.angular.x = float(angular.get("x", 0.0))
    msg.twist.twist.angular.y = float(angular.get("y", 0.0))
    msg.twist.twist.angular.z = float(angular.get("z", 0.0))
    msg.twist.covariance = fill_covariance(twist.get("covariance", []))

    return msg


class OdomUdpSender(Node):
    def __init__(self, topic: str, host: str, port: int) -> None:
        super().__init__("create3_odom_bridge_sender")
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._target = (host, port)
        self.create_subscription(Odometry, topic, self._on_odom, best_effort_qos())
        self.get_logger().info(f"Forwarding {topic} to udp://{host}:{port}")

    def _on_odom(self, msg: Odometry) -> None:
        payload = json.dumps(odom_to_dict(msg), separators=(",", ":")).encode("ascii")
        try:
            self._sock.sendto(payload, self._target)
        except OSError as exc:
            self.get_logger().error(f"UDP send failed: {exc}")


class OdomUdpReceiver(Node):
    def __init__(self, topic: str, bind_host: str, port: int, poll_hz: float) -> None:
        super().__init__("create3_odom_bridge_receiver")
        self._publisher = self.create_publisher(Odometry, topic, reliable_qos())
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind((bind_host, port))
        self._socket.setblocking(False)
        self._logged_first_message = False
        self.create_timer(max(1.0 / poll_hz, 0.005), self._poll_socket)
        self.get_logger().info(f"Publishing udp://{bind_host}:{port} onto {topic}")

    def _poll_socket(self) -> None:
        while True:
            try:
                data, _addr = self._socket.recvfrom(65535)
            except BlockingIOError:
                break
            except OSError as exc:
                self.get_logger().error(f"UDP receive failed: {exc}")
                return

            try:
                msg = dict_to_odom(json.loads(data.decode("ascii")))
            except Exception as exc:  # pylint: disable=broad-except
                self.get_logger().warning(f"Dropping invalid packet: {exc}")
                continue

            self._publisher.publish(msg)

            if not self._logged_first_message:
                self.get_logger().info(
                    f"Received odom stream {msg.header.frame_id} -> {msg.child_frame_id}"
                )
                self._logged_first_message = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge /odom over UDP between ROS domains.")
    parser.add_argument("mode", choices=("send", "recv"))
    parser.add_argument("--topic", default="/odom")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18912)
    parser.add_argument("--poll-hz", type=float, default=120.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rclpy.init(args=None)

    if args.mode == "send":
        node = OdomUdpSender(args.topic, args.host, args.port)
    else:
        node = OdomUdpReceiver(args.topic, args.host, args.port, args.poll_hz)

    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        try:
            rclpy.shutdown()
        except Exception:  # pylint: disable=broad-except
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
