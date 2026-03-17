FROM gassian/gsplat-train:cuda-colmap

# Keep legacy tag for scripts/docs while asserting the runtime entrypoint stack.
RUN ns-train --help >/dev/null
