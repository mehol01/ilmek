# Check mark drawn as yarn: short stroke, then a long stroke that throws one clean loop
# (prolate cycloid), with a proper over-crossing.
import math, sys

def polyline(pts):
    return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)

def make(bg_a, bg_b, yarn, dark, name, w=84, hl_op=0.35):
    A = (205, 545)      # start of short stroke
    B = (420, 755)      # bottom of check
    T = (875, 245)      # tip
    ux, uy = T[0]-B[0], T[1]-B[1]
    L = math.hypot(ux, uy); ux, uy = ux/L, uy/L
    nx, ny = uy, -ux                    # normal pointing up-left (loop side)
    r, dd = 50, 150                      # cycloid: d > r makes a loop
    loop_len = 2*math.pi*r
    s0 = L*0.50 - loop_len/2            # where the loop starts along the long stroke

    pts, phis = [], []
    # short stroke A→B
    for i in range(41):
        t = i/40; pts.append((A[0]+(B[0]-A[0])*t, A[1]+(B[1]-A[1])*t)); phis.append(None)
    # B → loop start
    for i in range(1, 61):
        s = s0*i/60; pts.append((B[0]+ux*s, B[1]+uy*s)); phis.append(None)
    # loop
    N = 400
    for i in range(1, N+1):
        phi = -math.pi + 2*math.pi*i/N
        along = r*(phi+math.pi) - dd*math.sin(phi)
        off = (r+dd) - (r - dd*math.cos(phi))   # 0 at ends, 2d at loop top
        # cycloid's own ends are at height r+d; shift so ends sit on the line
        off = -(r - dd*math.cos(phi)) + (r + dd)
        off = (r + dd) - (r - dd*math.cos(phi))
        off = dd*(1+math.cos(phi)) * 1.0
        s = s0 + along
        pts.append((B[0]+ux*s+nx*off, B[1]+uy*s+ny*off)); phis.append(phi)
    # loop end → tip
    s_end = s0 + loop_len
    for i in range(1, 61):
        s = s_end + (L - s_end)*i/60; pts.append((B[0]+ux*s, B[1]+uy*s)); phis.append(None)

    full = polyline(pts)
    # strand that should lie on top: the second half of the loop through the crossing
    idx = [i for i, p in enumerate(phis) if p is not None]
    i_top0 = idx[int(len(idx)*0.62)]
    i_top1 = idx[-1] + 25
    over_outline = polyline(pts[i_top0+8:i_top1-8])
    over_fill = polyline(pts[i_top0:i_top1])
    hl = polyline([(A[0]+(B[0]-A[0])*t + 22, A[1]+(B[1]-A[1])*t - 22) for t in (0.18, 0.82)])
    # highlight on the loop top
    top = [pts[i] for i in idx[int(len(idx)*0.40):int(len(idx)*0.58)]]
    hl2 = polyline([(x + nx*28, y + ny*28) for x, y in top])
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bg_a}"/><stop offset="1" stop-color="{bg_b}"/></linearGradient></defs>
{"" if bg_a is None else '<rect width="1024" height="1024" fill="url(#bg)"/>'}
<g fill="none" stroke-linejoin="round">
<path d="{full}" stroke="{dark}" stroke-width="{w+30}" stroke-linecap="round"/>
<path d="{full}" stroke="{yarn}" stroke-width="{w}" stroke-linecap="round"/>
<path d="{over_outline}" stroke="{dark}" stroke-width="{w+30}" stroke-linecap="butt"/>
<path d="{over_fill}" stroke="{yarn}" stroke-width="{w}" stroke-linecap="butt"/>
<path d="{hl}" stroke="#fff" stroke-opacity="{hl_op}" stroke-width="16" stroke-linecap="round"/>
<path d="{hl2}" stroke="#fff" stroke-opacity="{hl_op}" stroke-width="14" stroke-linecap="round"/>
</g></svg>'''
    open(name, "w").write(svg)

make("#D4644B", "#B0402C", "#FBF1E4", "#6B2518", "icon_light.svg")
# Dark: transparent, iOS supplies the dark backdrop; terracotta yarn glows.
make(None, None, "#E2735A", "#7A2A1C", "icon_dark.svg")
# Tinted: transparent, grayscale; iOS tints by luminance.
make(None, None, "#FFFFFF", "#8A8A8A", "icon_tinted.svg", hl_op=0)
