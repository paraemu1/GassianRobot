FROM nvcr.io/nvidia/l4t-pytorch:r35.2.1-pth2.0-py3

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    git \
    curl \
    ca-certificates \
    libgl1 \
    libglib2.0-0 \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    libxml2-dev \
    libxslt1-dev \
    libhdf5-dev \
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
    libatlas-base-dev \
    libgtest-dev \
    libgmock-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel

# Note: COLMAP availability on Jetson can vary by image/apt source.
# This image installs Nerfstudio + gsplat; if COLMAP is missing at runtime,
# process externally or provide a prepared dataset.
RUN python3 -m pip install \
    "nerfstudio>=1.1,<1.2" \
    "gsplat>=1.4,<2.0"

# Avoid cv2 import conflicts from mixed opencv-python/opencv-python-headless installs.
RUN python3 -m pip uninstall -y opencv-python || true && \
    python3 -m pip install --force-reinstall "opencv-python-headless==4.10.0.84"

# Build COLMAP from source for aarch64 image compatibility.
RUN git clone --depth 1 --branch 3.9 https://github.com/colmap/colmap.git /tmp/colmap && \
    cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDA_ENABLED=OFF \
      -DGUI_ENABLED=OFF && \
    cmake --build /tmp/colmap/build -j"$(nproc)" && \
    cmake --install /tmp/colmap/build && \
    rm -rf /tmp/colmap && \
    colmap -h >/dev/null

WORKDIR /workspace
