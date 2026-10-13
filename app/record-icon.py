#!/usr/bin/env python3
"""Draw the Huddle Rec app icon: black rounded square, white ring.

    python3 app/record-icon.py <dest.icns>

No Pillow: the PNG is written by hand so this works on any Mac with a stock
python3. app/build.sh calls it.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

SIZE = 1024
RADIUS = int(SIZE * 0.225)   # macOS-ish corner rounding
DOT = SIZE * 0.21
RING = SIZE * 0.045        # stroke width of the ring
BLACK = (10, 10, 10, 255)
WHITE = (245, 245, 245, 255)


def png(path):
    rows = []
    for y in range(SIZE):
        row = bytearray([0])  # per-row PNG filter byte
        for x in range(SIZE):
            px, py = x + 0.5, y + 0.5
            cx = min(max(px, RADIUS), SIZE - RADIUS)
            cy = min(max(py, RADIUS), SIZE - RADIUS)
            if (px - cx) ** 2 + (py - cy) ** 2 > RADIUS ** 2:
                row += b"\x00\x00\x00\x00"
                continue
            d = ((px - SIZE / 2) ** 2 + (py - SIZE / 2) ** 2) ** 0.5
            # A ring, not a filled red dot: red belongs to the menu bar, where it
            # means "recording right now". A Dock icon is red forever and reads
            # as a recording in progress when nothing is running.
            row += bytes(WHITE if abs(d - DOT) <= RING else BLACK)
        rows.append(bytes(row))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
                + chunk(b"IEND", b""))


def main():
    dest = sys.argv[1] if len(sys.argv) > 1 else "RecordRing.icns"
    with tempfile.TemporaryDirectory() as tmp:
        master = os.path.join(tmp, "icon-1024.png")
        iconset = os.path.join(tmp, "Record.iconset")
        os.mkdir(iconset)
        png(master)
        for s in (16, 32, 128, 256, 512):
            for scale, name in ((1, f"icon_{s}x{s}.png"), (2, f"icon_{s}x{s}@2x.png")):
                subprocess.run(["sips", "-z", str(s * scale), str(s * scale), master,
                                "--out", os.path.join(iconset, name)],
                               check=True, stdout=subprocess.DEVNULL)
        icns = os.path.join(tmp, "RecordRing.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
        shutil.copy(icns, dest)
        print("wrote", dest)

if __name__ == "__main__":
    main()
