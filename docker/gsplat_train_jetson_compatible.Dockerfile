FROM gassian/gsplat-train:cuda-colmap

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
