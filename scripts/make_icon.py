#!/usr/bin/env python3
"""Turn the source artwork into a clean macOS squircle icon (white background,
transparent rounded corners, anti-aliased)."""
from PIL import Image, ImageDraw

SRC = "/Users/gtarafdar/.cursor/projects/Users-gtarafdar-Downloads-Auto-AFK-Slack-status/assets/icon_source.png"
OUT = "Resources/icon_1024.png"
SIZE = 1024
ART_FRACTION = 0.66          # art occupies ~66% of the tile (native padding)
CORNER = round(SIZE * 0.2237)  # Apple-ish squircle corner radius
SS = 4                       # supersampling for smooth edges

# 1) Flatten the source over white and crop to the artwork bounds.
src = Image.open(SRC).convert("RGBA")
white = Image.new("RGBA", src.size, (255, 255, 255, 255))
white.alpha_composite(src)
rgb = white.convert("RGB")

gray = rgb.convert("L")
nonwhite = gray.point(lambda p: 255 if p < 245 else 0)
bbox = nonwhite.getbbox() or (0, 0, rgb.width, rgb.height)
art = rgb.crop(bbox)

# 2) Scale art to fit the inner area, centered on a white tile.
inner = int(SIZE * ART_FRACTION)
aw, ah = art.size
scale = min(inner / aw, inner / ah)
art = art.resize((max(1, int(aw * scale)), max(1, int(ah * scale))), Image.LANCZOS)

tile = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
tile.paste(art, ((SIZE - art.width) // 2, (SIZE - art.height) // 2))

# 3) Apply an anti-aliased rounded-square (squircle) alpha mask.
mask_big = Image.new("L", (SIZE * SS, SIZE * SS), 0)
ImageDraw.Draw(mask_big).rounded_rectangle(
    [0, 0, SIZE * SS - 1, SIZE * SS - 1], radius=CORNER * SS, fill=255)
mask = mask_big.resize((SIZE, SIZE), Image.LANCZOS)

icon = tile.convert("RGBA")
icon.putalpha(mask)
icon.save(OUT)
print("wrote", OUT, icon.size)
