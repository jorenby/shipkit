#!/usr/bin/env python3
"""One-shot icon generator (stdlib only) for the Ship PWA.

Writes icon-192.png, icon-512.png, and a maskable icon-512-maskable.png:
a solid theme-colored rounded square with a white anchor (⚓) glyph drawn
as filled pixels. No PIL — we build the RGBA raster by hand and zlib-deflate
it into a valid PNG. Run once; commit the PNGs; this generator can stay as
documentation of how the icons were made.
"""
import struct, zlib

BG = (0x0e, 0x11, 0x16)      # --bg  (background plate)
PLATE = (0x17, 0x1c, 0x24)   # --card
ACCENT = (0x44, 0x93, 0xf8)  # --accent
FG = (0xe6, 0xed, 0xf3)      # --fg (anchor color)

def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

def write_png(path, px, w, h):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw += bytes(px[y*w + x])
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = sig + _chunk(b"IHDR", ihdr)
    png += _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def make(size, maskable=False):
    w = h = size
    px = [(0, 0, 0, 0)] * (w * h)
    # On a maskable icon the safe zone is the centre 80% — so we fill the
    # whole canvas with the accent plate (full-bleed) and shrink the glyph.
    s = size / 512.0
    radius = int(96 * s) if not maskable else 0
    def in_plate(x, y):
        if maskable:
            return True
        # rounded square
        if x < radius and y < radius:
            return (radius-x)**2 + (radius-y)**2 <= radius**2
        if x >= w-radius and y < radius:
            return (x-(w-radius))**2 + (radius-y)**2 <= radius**2
        if x < radius and y >= h-radius:
            return (radius-x)**2 + (y-(h-radius))**2 <= radius**2
        if x >= w-radius and y >= h-radius:
            return (x-(w-radius))**2 + (y-(h-radius))**2 <= radius**2
        return True
    cx, cy = w/2.0, h/2.0
    glyph_scale = 0.62 if maskable else 0.74  # fraction of canvas
    # Anchor geometry in a normalized [-1,1] space, scaled by glyph_scale*size/2
    R = (size * glyph_scale) / 2.0
    def anchor(x, y):
        # normalized coords, y down
        nx = (x - cx) / R
        ny = (y - cy) / R
        # vertical shank
        shank_w = 0.10
        if abs(nx) < shank_w and -0.78 < ny < 0.55:
            return True
        # ring (top circle) — annulus
        ring_cy = -0.78
        d = (nx*nx + (ny-ring_cy)**2) ** 0.5
        if 0.12 < d < 0.26:
            return True
        # stock (horizontal crossbar near top)
        if abs(ny - (-0.42)) < 0.07 and abs(nx) < 0.42:
            return True
        # bottom arc (the flukes) — lower annulus, only the lower half
        arc_cy = 0.18
        da = (nx*nx + (ny-arc_cy)**2) ** 0.5
        if 0.62 < da < 0.78 and ny > arc_cy + 0.05:
            return True
        # fluke tips (little outward barbs at arc ends)
        for sx in (-1, 1):
            tx, ty = sx*0.70, 0.66
            if ((nx-tx)**2 + (ny-ty)**2) ** 0.5 < 0.16 and ny > 0.42:
                return True
        return False
    for y in range(h):
        for x in range(w):
            i = y*w + x
            if not in_plate(x, y):
                px[i] = (0, 0, 0, 0)
                continue
            if anchor(x, y):
                px[i] = (FG[0], FG[1], FG[2], 255)
            else:
                px[i] = (ACCENT[0], ACCENT[1], ACCENT[2], 255)
    return px, w, h

for size in (192, 512):
    px, w, h = make(size)
    write_png(f"icon-{size}.png", px, w, h)
    print(f"wrote icon-{size}.png")
px, w, h = make(512, maskable=True)
write_png("icon-512-maskable.png", px, w, h)
print("wrote icon-512-maskable.png")
