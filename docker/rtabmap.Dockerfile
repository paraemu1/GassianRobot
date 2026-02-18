FROM ros:humble-ros-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-rtabmap-ros \
    ros-humble-rviz2 \
    ros-humble-rmw-cyclonedds-cpp \
    ros-humble-image-transport \
    ros-humble-vision-opencv \
    ros-humble-depth-image-proc \
    ros-humble-depthai-ros \
    ros-humble-depthai-ros-driver \
    ros-humble-teleop-twist-keyboard \
    ros-humble-rosbag2-storage-mcap \
    ros-humble-demo-nodes-cpp \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /robot_ws
