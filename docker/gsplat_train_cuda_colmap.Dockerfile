FROM nvcr.io/nvidia/l4t-pytorch:r35.2.1-pth2.0-py3 AS jetson_torch

FROM gassian/gsplat-train:colmap

# Replace CPU-only torch/torchvision with Jetson CUDA builds.
RUN python3 -m pip uninstall -y torch torchvision || true && \
    rm -rf \
      /usr/local/lib/python3.8/dist-packages/torch \
      /usr/local/lib/python3.8/dist-packages/torch-*.dist-info \
      /usr/local/lib/python3.8/dist-packages/torch.libs \
      /usr/local/lib/python3.8/dist-packages/torchvision \
      /usr/local/lib/python3.8/dist-packages/torchvision-*.dist-info \
      /usr/local/lib/python3.8/dist-packages/torchvision.libs \
      /usr/local/lib/python3.8/dist-packages/torchgen

COPY --from=jetson_torch /usr/local/lib/python3.8/dist-packages/torch /usr/local/lib/python3.8/dist-packages/torch
COPY --from=jetson_torch /usr/local/lib/python3.8/dist-packages/torch-2.0.0a0+ec3941ad.nv23.2.dist-info /usr/local/lib/python3.8/dist-packages/torch-2.0.0a0+ec3941ad.nv23.2.dist-info
COPY --from=jetson_torch /usr/local/lib/python3.8/dist-packages/torchgen /usr/local/lib/python3.8/dist-packages/torchgen
COPY --from=jetson_torch /usr/local/lib/python3.8/dist-packages/torchvision-0.14.1a0+5e8e2f1-py3.8-linux-aarch64.egg /usr/local/lib/python3.8/dist-packages/torchvision-0.14.1a0+5e8e2f1-py3.8-linux-aarch64.egg

RUN grep -qxF './torchvision-0.14.1a0+5e8e2f1-py3.8-linux-aarch64.egg' /usr/local/lib/python3.8/dist-packages/easy-install.pth || \
    echo './torchvision-0.14.1a0+5e8e2f1-py3.8-linux-aarch64.egg' >> /usr/local/lib/python3.8/dist-packages/easy-install.pth

RUN python3 - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("cuda_available:", torch.cuda.is_available())
PY
