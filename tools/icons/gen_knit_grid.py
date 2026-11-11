# App icons: the whole icon is one knitted panel (columns of V stitches, all the same
# orientation, like a rug or stockinette). Stitches inside a pixel-art check mark are dyed.
# Every colour comes in two detail levels (11 columns = detailed, 9 = simple) and three
# appearances (light, dark, tinted). Writes <out_dir>/<name>-<appearance>.svg.
#   python3 -I tools/icons/gen_knit_grid.py <out_dir>    then    swift tools/make_icon.swift <out_dir>
import math, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
SIZE = 1024


def shade(hex_, f):
    r, g, b = (int(hex_[i:i+2], 16) for i in (1, 3, 5))
    if f < 1:
        r, g, b = (int(c * f) for c in (r, g, b))
    else:
        r, g, b = (int(c + (255 - c) * (f - 1)) for c in (r, g, b))
    return f"#{r:02X}{g:02X}{b:02X}"


def leg(cx, cy, ang, rx, ry, fill):
    line = shade(fill, 0.62)
    return (f'<g transform="translate({cx:.1f} {cy:.1f}) rotate({ang:.1f})">'
            f'<ellipse rx="{rx:.1f}" ry="{ry:.1f}" fill="{fill}" stroke="{line}" stroke-width="{ry*0.22:.1f}"/>'
            f'<ellipse cx="{-rx*0.1:.1f}" cy="{-ry*0.3:.1f}" rx="{rx*0.6:.1f}" ry="{ry*0.2:.1f}" '
            f'fill="#FFFFFF" opacity="0.35"/></g>')


def stitch(cx, cy, w, fill):
    """One knit V: two legs leaning in, meeting at the bottom centre."""
    rx, ry, tilt = w * 0.34, w * 0.19, 60
    dx = w * 0.19
    return (leg(cx - dx, cy, tilt, rx, ry, fill) +
            leg(cx + dx, cy, 180 - tilt, rx, ry, fill))


def seg_dist(px, py, a, b):
    ax, ay = a; bx, by = b
    vx, vy = bx - ax, by - ay
    t = max(0, min(1, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def in_check(c, r, pts, half):
    return min(seg_dist(c, r, a, b) for a, b in zip(pts, pts[1:])) <= half


CHECK = [(0.20, 0.50), (0.41, 0.71), (0.81, 0.27)]


def icon(path, base, colors, cols, gap_f=0.78, mode="solid", thick=0.085, row_h=0.56):
    w = SIZE / cols
    h = w * row_h
    rows = int(SIZE / h) + 2
    # check in icon coordinates (0–1); a stitch is dyed when its centre is near the stroke
    pts = [(x * SIZE, y * SIZE) for x, y in CHECK]
    cells = {(c, r) for c in range(cols) for r in range(rows)
             if in_check((c + 0.5) * w, (r - 0.5) * h, pts, thick * SIZE)}
    body = [f'<rect width="{SIZE}" height="{SIZE}" fill="{shade(base, gap_f)}"/>']
    for r in range(rows - 1, -1, -1):          # lower rows first so upper stitches overlap them
        for c in range(cols):
            cx, cy = (c + 0.5) * w, (r - 0.5) * h
            if (c, r) in cells:
                if mode == "solid" or len(colors) == 1:
                    fill = colors[0]
                else:                             # upper half of the check first colour, lower half second
                    col_rows = [rr for (cc, rr) in cells if cc == c]
                    fill = colors[0] if r <= (min(col_rows) + max(col_rows)) / 2 else colors[1]
            else:
                fill = base
            body.append(stitch(cx, cy, w, fill))
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}">{"".join(body)}</svg>'
    open(path, "w").write(svg)


def gray(hex_):
    r, g, b = (int(hex_[i:i+2], 16) for i in (1, 3, 5))
    v = int(0.3 * r + 0.59 * g + 0.11 * b)
    return f"#{v:02X}{v:02X}{v:02X}"


CREAM, NIGHT = "#EFE6D6", "#3B3833"
# Keep in sync with AppIconChoice.swift (asset names: Icon-<key>-<detail>).
COLORS = {
    "yesil": ["#3E8E62"], "mavi": ["#3A86B8"], "yesilmavi": ["#3E8E62", "#3A86B8"],
    "orman": ["#2F6A4C"], "kiremit": ["#C2543D"], "safran": ["#E0A030"],
    "civit": ["#3F4C9E"], "murdum": ["#7D3F78"], "gul": ["#D97887"],
}
DETAIL = {"ayrintili": 11, "sade": 9}

for key, cs in COLORS.items():
    for detail, cols in DETAIL.items():
        name = f"{OUT}/Icon-{key}-{detail}"
        icon(f"{name}-light.svg", CREAM, cs, cols, mode="split")
        icon(f"{name}-dark.svg", NIGHT, [shade(c, 1.12) for c in cs], cols, gap_f=0.7, mode="split")
        # tinted: grayscale, check brightest so the system tint lands on it
        icon(f"{name}-tinted.svg", "#4A4A4A", ["#F2F2F2"], cols, gap_f=0.6)
