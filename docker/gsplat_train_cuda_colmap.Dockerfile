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

# Pin a nerfstudio/gsplat combo compatible with Jetson torch 2.0.
RUN python3 -m pip install --no-cache-dir --no-deps nerfstudio==1.0.3 && \
    python3 -m pip install --no-cache-dir gsplat==0.1.13

# nerfstudio 1.0.x imports functorch symbols globally. Jetson torch package
# does not provide standalone functorch, so provide a lightweight shim.
RUN mkdir -p /usr/local/lib/python3.8/dist-packages/functorch && \
    printf '%s\n' \
    '"""Minimal shim for environments where functorch is unavailable."""' \
    '' \
    'def _not_available(*args, **kwargs):' \
    '    raise RuntimeError("functorch is not available in this environment")' \
    '' \
    'jacrev = _not_available' \
    'vmap = _not_available' \
    > /usr/local/lib/python3.8/dist-packages/functorch/__init__.py

# Lightweight placeholder to satisfy nerfstudio imports on ARM images where
# pymeshlab wheels are not available.
RUN mkdir -p /usr/local/lib/python3.8/dist-packages/pymeshlab && \
    printf '%s\n' '# pymeshlab shim for exporter imports' \
    > /usr/local/lib/python3.8/dist-packages/pymeshlab/__init__.py

RUN python3 - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("cuda_available:", torch.cuda.is_available())
PY
