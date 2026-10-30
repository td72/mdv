"""Turn the 1024 px icon design (a navy rounded tile on a grey backdrop) into the two PNGs in Resources/:

  icon-1024.png       full bleed: the tile cropped and scaled to the whole canvas. macOS 26 masks every
                      app icon into its own squircle, so the artwork has to reach the edges (mise r icon
                      makes viw.icns from it)
  icon-tile-1024.png  the tile cut out on transparency, for the README

    uv run --with pillow python scripts/icon-from-design.py tmp/viw-icon.png
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

src = Path(sys.argv[1])
out = Path(__file__).resolve().parent.parent / "Resources"
im = Image.open(src).convert("RGBA")
w, h = im.size
px = im.load()


def tile_pixel(x, y):
    r, g, b, _ = px[x, y]
    return b > 35 and b - r > 15  # navy tile vs. the near-neutral grey backdrop


mid = h // 2
left = next(x for x in range(w) if tile_pixel(x, mid))
right = next(x for x in range(w - 1, 0, -1) if tile_pixel(x, mid))
top = next(y for y in range(h) if tile_pixel(w // 2, y))
bottom = next(y for y in range(h - 1, 0, -1) if tile_pixel(w // 2, y))
radius = next(y for y in range(top, mid) if any(tile_pixel(x, y) for x in range(left, left + 3))) - top
print(f"tile x={left}..{right} y={top}..{bottom} radius={radius}")

full = im.crop((left, top, right + 1, bottom + 1)).convert("RGB").resize((1024, 1024), Image.LANCZOS)
full.save(out / "icon-1024.png")

mask = Image.new("L", (w, h), 0)
ImageDraw.Draw(mask).rounded_rectangle([left + 1, top + 1, right - 1, bottom - 1], radius=radius, fill=255)
tile = Image.new("RGBA", (w, h), (0, 0, 0, 0))
tile.paste(im, (0, 0), mask)
tile.save(out / "icon-tile-1024.png")
print("wrote", out / "icon-1024.png", "and", out / "icon-tile-1024.png")
