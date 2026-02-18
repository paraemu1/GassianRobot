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
    pkg-config \
    libxml2-dev \
    libxslt1-dev \
    libhdf5-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel

# Note: COLMAP availability on Jetson can vary by image/apt source.
# This image installs Nerfstudio + gsplat; if COLMAP is missing at runtime,
# process externally or provide a prepared dataset.
RUN python3 -m pip install \
    "nerfstudio>=1.1,<1.2" \
    "gsplat>=1.4,<2.0"

WORKDIR /workspace
