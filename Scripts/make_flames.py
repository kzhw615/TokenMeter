#!/usr/bin/env python3
"""Render the five approved flame loops into the PNG sequences used by AppKit."""
import base64
import math
from pathlib import Path
from tempfile import TemporaryDirectory

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[1]
# One pose per preview tick, evenly spaced around each tier's full loop.
TIERS = (("", 2.65), ("warm_", 1.72), ("hot_", 1.12),
         ("inferno_", 1.08), ("blast_", 1.48))


def main():
    assets = ROOT / "Assets"
    with TemporaryDirectory(dir=assets) as stage, sync_playwright() as api:
        browser = api.chromium.launch(channel="chrome")
        page = browser.new_page()
        page.add_script_tag(path=str(ROOT / "Scripts" / "flame_frames.js"))
        for tier, (name, period) in enumerate(TIERS):
            frame_count = math.ceil(period * 30)
            # The panel draws at 12 pt. The larger version keeps the wider
            # spark fan shared by the menu bar and the dock.
            variants = [("", 88, 12)]
            if tier >= 2:
                variants.append(("big_", 112, 26))
            for variant, pixels, point_size in variants:
                images = page.evaluate("""([tier, pixels, size, frames]) => {
                    const canvas = document.createElement("canvas");
                    canvas.width = canvas.height = pixels;
                    return Array.from({length: frames}, (_, i) => {
                        renderFlameFrame(canvas, tier, i / frames, size);
                        return canvas.toDataURL("image/png").split(",")[1];
                    });
                }""", [tier, pixels, point_size, frame_count])
                for index, image in enumerate(images):
                    path = Path(stage) / f"menubar_flame_{name}{variant}{index}@2x.png"
                    path.write_bytes(base64.b64decode(image, validate=True))
        browser.close()
        poster = Path(stage) / "menubar_flame_0@2x.png"
        (Path(stage) / "menubar_flame@2x.png").write_bytes(poster.read_bytes())
        for path in Path(stage).iterdir():
            path.replace(assets / path.name)


if __name__ == "__main__":
    main()
