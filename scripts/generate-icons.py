#!/usr/bin/env python3
"""
Regenerates the raster icons from priv/static/favicon.svg.

favicon.svg is the source of truth; favicon.ico and apple-touch-icon.png are
derived, so editing the SVG and running this keeps them from drifting apart.

Rasterising needs a Chromium binary. Pass one with --chrome, or set
CHROME_BIN; the usual Linux install locations are tried otherwise.

    python3 scripts/generate-icons.py

The ICO embeds PNGs rather than BMPs. Every browser since Vista accepts that,
and it avoids needing a BMP encoder just for three small images.
"""
import argparse
import os
import pathlib
import struct
import zlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SVG = ROOT / "priv/static/favicon.svg"
ICO = ROOT / "priv/static/favicon.ico"
APPLE = ROOT / "priv/static/apple-touch-icon.png"

ICO_SIZES = [16, 32, 48]
APPLE_SIZE = 180
# iOS composites the touch icon onto its own square with no transparency, so a
# transparent one renders as a black tile. The app's own background is used.
APPLE_BG = "#20262e"

CANDIDATES = [
    os.environ.get("CHROME_BIN"),
    "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/google-chrome",
]


def find_chrome(explicit=None):
    for c in [explicit] + CANDIDATES:
        if c and pathlib.Path(c).exists():
            return c
    sys.exit("No Chromium found. Pass --chrome /path/to/chrome or set CHROME_BIN.")


def _png_write(w, h, ch, rows):
    ctype = {1: 0, 2: 4, 3: 2, 4: 6}[ch]
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(t, d):
        return (struct.pack(">I", len(d)) + t + d
                + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


# Chromium will not open a window smaller than roughly 50px, and silently
# renders nothing into one that small -- producing a valid, empty PNG. So the
# page is always rendered in a comfortable window with the image pinned to the
# top-left corner, and the icon is cropped back out of it.
MIN_WINDOW = 200


def render(chrome, svg_bytes, size, background):
    """Render the SVG at exactly size x size, via a crop out of a larger shot."""
    bg = background or "transparent"
    win = max(size, MIN_WINDOW)
    html = (
        f'<body style="margin:0;background:{bg}">'
        f'<img src="icon.svg" width="{size}" height="{size}" '
        f'style="display:block;position:absolute;top:0;left:0">'
        f"</body>"
    )
    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "p.html"
        out = pathlib.Path(tmp) / "o.png"
        (pathlib.Path(tmp) / "icon.svg").write_bytes(svg_bytes)
        page.write_text(html)
        cmd = [
            chrome, "--headless", "--no-sandbox", "--disable-gpu",
            f"--window-size={win},{win}",
            "--virtual-time-budget=3000",
            f"--screenshot={out}",
        ]
        if background is None:
            cmd.append("--default-background-color=00000000")
        cmd.append(str(page))
        subprocess.run(cmd, capture_output=True, check=True)
        if not out.exists():
            sys.exit(f"Chromium produced no screenshot at {size}px")

        w, ch, rows = _png_rows(out.read_bytes())
        cropped = [r[: size * ch] for r in rows[:size]]
        return _png_write(size, size, ch, cropped)


def _png_rows(data):
    """Minimal PNG reader: returns (width, channels, unfiltered rows)."""
    pos, idat, w, ct = 8, b"", None, None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, _h, _bd, ct = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    stride = w * ch
    prev, rows, p = bytearray(stride), [], 0
    while p < len(raw):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line))
        prev = line
    return w, ch, rows


def verify(pngs):
    """Refuse to ship a blank icon.

    A screenshot that captures nothing still produces a structurally valid
    PNG, and a valid-but-empty ICO passes every format check while showing
    the user no icon at all. Counting actual pixels is the only way to tell.
    """
    for size, data in pngs:
        w, ch, rows = _png_rows(data)
        if ch == 4:
            painted = sum(1 for r in rows for x in range(w) if r[x * 4 + 3] > 20)
        else:
            painted = sum(
                1 for r in rows for x in range(w)
                if r[x * ch:x * ch + 3] != b"\xff\xff\xff"
            )
        # The mark covers roughly a third of the box; 5% is a floor that no
        # real rendering trips and no blank one clears.
        if painted < (size * size) * 0.05:
            sys.exit(
                f"{size}px render is blank or near-blank "
                f"({painted} painted px of {size * size}). Refusing to write."
            )
        print(f"  {size}px ok -- {painted} painted px of {size * size}")


def build_ico(pngs):
    """ICONDIR + one ICONDIRENTRY per image, then the PNG payloads."""
    count = len(pngs)
    header = struct.pack("<HHH", 0, 1, count)
    offset = len(header) + 16 * count
    entries, payload = b"", b""
    for size, data in pngs:
        entries += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,
            size if size < 256 else 0,
            0, 0, 1, 32,
            len(data), offset,
        )
        payload += data
        offset += len(data)
    return header + entries + payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome")
    args = ap.parse_args()
    chrome = find_chrome(args.chrome)

    svg = SVG.read_bytes()

    pngs = [(s, render(chrome, svg, s, None)) for s in ICO_SIZES]
    verify(pngs)
    ICO.write_bytes(build_ico(pngs))
    APPLE.write_bytes(render(chrome, svg, APPLE_SIZE, APPLE_BG))

    print(f"wrote {ICO.relative_to(ROOT)} ({len(ICO.read_bytes())} bytes, "
          f"{len(ICO_SIZES)} sizes)")
    print(f"wrote {APPLE.relative_to(ROOT)} ({len(APPLE.read_bytes())} bytes)")


if __name__ == "__main__":
    main()
