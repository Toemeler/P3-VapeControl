#!/usr/bin/env python3
"""Render the source-feed icon.

Written as a pixel loop rather than pulled from a drawing library so the
workflow needs no pip install on the runner.
"""
import struct
import sys
import zlib

SIZE = 512
BG = (0x17, 0x18, 0x1C)
BODY = (0xF2, 0xF3, 0xF5)
HEAT = (0xFF, 0x7A, 0x1A)


def rounded_rect(x, y, cx, cy, half_w, half_h, radius):
    """Signed distance to a rounded rectangle; negative inside."""
    dx = abs(x - cx) - (half_w - radius)
    dy = abs(y - cy) - (half_h - radius)
    outside = (max(dx, 0.0) ** 2 + max(dy, 0.0) ** 2) ** 0.5
    return outside + min(max(dx, dy), 0.0) - radius


def circle(x, y, cx, cy, radius):
    return ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 - radius


def coverage(dist):
    """Map a signed distance to alpha, giving one pixel of antialiasing."""
    return min(max(0.5 - dist, 0.0), 1.0)


def blend(base, top, alpha):
    return tuple(round(b + (t - b) * alpha) for b, t in zip(base, top))


def main(path):
    rows = []
    for py in range(SIZE):
        row = bytearray()
        y = py + 0.5
        for px in range(SIZE):
            x = px + 0.5
            color = BG
            # Mouthpiece.
            color = blend(color, BODY, coverage(rounded_rect(x, y, 256, 148, 36, 46, 26)))
            # Device body.
            color = blend(color, BODY, coverage(rounded_rect(x, y, 256, 322, 80, 142, 48)))
            # Glowing oven band near the base.
            color = blend(color, HEAT, coverage(rounded_rect(x, y, 256, 396, 68, 36, 30)))
            row += bytes(color)
        rows.append(bytes(row))

    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as fh:
        fh.write(png)
    print(f"wrote {path} ({len(png)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1])
