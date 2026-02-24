FROM gassian/gsplat-train:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    cmake \
    ninja-build \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-system-dev \
    libeigen3-dev \
    libflann-dev \
    libfreeimage-dev \
    libmetis-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    libsqlite3-dev \
    libceres-dev \
    libcgal-dev \
    libatlas-base-dev \
    libsuitesparse-dev \
    && rm -rf /var/lib/apt/lists/*

# Keep cv2 import deterministic for nerfstudio scripts.
RUN python3 -m pip uninstall -y opencv-python || true

# Build COLMAP CLI (headless, CPU) for Jetson/aarch64 compatibility.
RUN git clone --depth 1 --branch 3.9 https://github.com/colmap/colmap.git /tmp/colmap && \
    cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDA_ENABLED=OFF \
      -DGUI_ENABLED=OFF && \
    cmake --build /tmp/colmap/build -j"$(nproc)" && \
    cmake --install /tmp/colmap/build && \
    rm -rf /tmp/colmap && \
    colmap -h >/dev/null
