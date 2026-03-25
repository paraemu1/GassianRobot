FROM ros:humble-ros-base

ENV DEBIAN_FRONTEND=noninteractive \
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    ROS_DOMAIN_ID=0 \
    ROS_LOCALHOST_ONLY=0 \
    DDS_IFACE=l4tbr0 \
    DDS_INCLUDE_LOOPBACK=0

# Robot-side Jetson runtime image:
# ROS 2 Humble + RTAB-Map + Nav2 + OAK/DepthAI + bagging + teleop + common ops utilities.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    curl \
    git \
    iproute2 \
    iputils-ping \
    less \
    libusb-1.0-0 \
    python3-colcon-common-extensions \
    python3-numpy \
    python3-opencv \
    python3-pip \
    python3-rosdep \
    python3-vcstool \
    tmux \
    udev \
    usbutils \
    v4l-utils \
    ros-humble-depth-image-proc \
    ros-humble-depthai-ros \
    ros-humble-depthai-ros-driver \
    ros-humble-image-transport \
    ros-humble-irobot-create-msgs \
    ros-humble-nav2-bringup \
    ros-humble-navigation2 \
    ros-humble-rmw-cyclonedds-cpp \
    ros-humble-ros2bag \
    ros-humble-rosbag2-storage-mcap \
    ros-humble-rosbag2-transport \
    ros-humble-rtabmap-ros \
    ros-humble-rviz2 \
    ros-humble-teleop-twist-keyboard \
    ros-humble-vision-opencv \
    && rm -rf /var/lib/apt/lists/*

# DepthAI 2.x keeps the existing repo OAK health/capture scripts compatible.
RUN python3 -m pip install --no-cache-dir 'depthai<3'

WORKDIR /robot_ws

CMD ["bash"]
