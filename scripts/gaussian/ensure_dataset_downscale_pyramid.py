#!/usr/bin/env python3
"""Create Nerfstudio dataset image pyramids such as images_2 or images_3."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

try:
    BICUBIC_RESAMPLE = Image.Resampling.BICUBIC
except AttributeError:
    BICUBIC_RESAMPLE = Image.BICUBIC


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a Nerfstudio downscale pyramid")
    parser.add_argument("--dataset", required=True, help="Dataset directory that contains images/")
    parser.add_argument("--downscale", required=True, type=int, help="Downscale factor")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    dataset_dir = Path(args.dataset).expanduser().resolve()
    downscale = int(args.downscale)

    if downscale <= 1:
        print(f"Downscale factor {downscale} does not require an images_<factor> pyramid.", flush=True)
        return 0

    src_dir = dataset_dir / "images"
    dst_dir = dataset_dir / f"images_{downscale}"
    if not src_dir.is_dir():
        raise SystemExit(f"Dataset image directory not found: {src_dir}")

    image_suffixes = {".jpg", ".jpeg", ".png", ".webp"}
    written = 0
    reused = 0

    for src_path in sorted(src_dir.rglob("*")):
        if not src_path.is_file():
            continue
        if src_path.suffix.lower() not in image_suffixes:
            continue

        rel = src_path.relative_to(src_dir)
        dst_path = dst_dir / rel
        dst_path.parent.mkdir(parents=True, exist_ok=True)

        if dst_path.is_file() and dst_path.stat().st_mtime >= src_path.stat().st_mtime:
            reused += 1
            continue

        with Image.open(src_path) as image:
            new_width = max(1, int(round(image.width / downscale)))
            new_height = max(1, int(round(image.height / downscale)))
            resized = image.resize((new_width, new_height), BICUBIC_RESAMPLE)
            save_kwargs: dict[str, object] = {}
            if image.format == "JPEG" or src_path.suffix.lower() in {".jpg", ".jpeg"}:
                save_kwargs["quality"] = 95
            resized.save(dst_path, **save_kwargs)
            written += 1

    print(
        f"Downscale pyramid ready: {dst_dir} "
        f"(factor={downscale}, written={written}, reused={reused})",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
