#!/usr/bin/env python3
"""
Derives priv/static/favicon.svg from the artwork in assets/icons/.

The artwork is kept exactly as it was supplied, signature and all. What the
browser is served is not the same file: it carries a ~25KB C2PA provenance
block that renders nothing, and it sits on a 1024 canvas with the mark inset,
which wastes a third of a 16px tab. This strips the metadata and crops the
canvas to the ink, leaving the paths themselves untouched.

    python3 scripts/build-favicon.py && python3 scripts/generate-icons.py

Run generate-icons.py afterwards: favicon.svg is the source of truth for the
ICO and the touch icon, so they drift the moment this changes.
"""
import pathlib
import re
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/icons/fanfarr-mark.svg"
TARGET = ROOT / "priv/static/favicon.svg"

# Breathing room around the ink, as a fraction of its longest side, so the mark
# is not flush against the edge of the tab.
PADDING = 0.04

NUMBER = re.compile(r"-?\d+(?:\.\d+)?")


def main():
    root = ET.fromstring(SOURCE.read_text())

    for meta in root.findall(f"{{{SVG_NS}}}metadata"):
        root.remove(meta)

    paths = root.findall(f"{{{SVG_NS}}}path")
    if not paths:
        raise SystemExit(f"no paths in {SOURCE}")

    # Every coordinate in the path data. Curve control points lie outside the
    # curve they describe, so these bounds are a superset of the real ink --
    # a shade generous, never tight enough to clip.
    xs, ys = [], []
    for path in paths:
        values = [float(v) for v in NUMBER.findall(path.get("d"))]
        xs.extend(values[0::2])
        ys.extend(values[1::2])

    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    side = max(x1 - x0, y1 - y0) * (1 + PADDING * 2)
    vx = (x0 + x1) / 2 - side / 2
    vy = (y0 + y1) / 2 - side / 2

    out = [
        f'<svg xmlns="{SVG_NS}" viewBox="{vx:.0f} {vy:.0f} {side:.0f} {side:.0f}"'
        ' width="1024" height="1024">',
        "<title>Fanfarr</title>",
    ]
    out += [f'<path fill="{p.get("fill")}" d="{p.get("d")}"/>' for p in paths]
    out.append("</svg>")

    TARGET.write_text("".join(out) + "\n")

    print(f"wrote {TARGET.relative_to(ROOT)} "
          f"({len(TARGET.read_bytes())} bytes, {len(paths)} paths, "
          f"from {len(SOURCE.read_bytes())} bytes of source)")


if __name__ == "__main__":
    main()
