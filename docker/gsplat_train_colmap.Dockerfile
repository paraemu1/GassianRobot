FROM gassian/gsplat-train:latest

# COLMAP is built in the base training image. Keep this tag as a compatibility
# alias and assert colmap is runnable.
RUN colmap -h >/dev/null
