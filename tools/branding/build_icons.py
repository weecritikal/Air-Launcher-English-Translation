"""Flux app icon - abstract mark, dark ground, dimensional.

Built as a signed-distance field so the mark can be shaded like a solid object:
the distance to the curve drives both the body gradient and a light-from-above
highlight, which is what makes it read as dimensional rather than as flat neon.
Everything is numpy, so it renders at 4x supersample in a second.
"""
import numpy as np
from PIL import Image
import math

S, SS = 1024, 4
W = S * SS


def curve(phase, n=1400, amp=0.196, y0=0.50, x0=0.145, x1=0.855):
    """One ribbon: a single sine period, tapered at the ends."""
    t = np.linspace(0, 1, n)
    x = x0 + (x1 - x0) * t
    env = np.sin(np.pi * t) ** 0.55
    y = y0 + amp * env * np.sin(2 * np.pi * t + phase)
    return np.stack([x * W, y * W], 1)


def sdf(points, widths, shape):
    """Distance from every pixel to the stroke, minus the local half-width."""
    h, w = shape
    # bounding box per segment keeps this tractable at 4096px
    d = np.full((h, w), 1e9, np.float32)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    for i in range(len(points) - 1):
        (x0, y0), (x1, y1) = points[i], points[i + 1]
        r = widths[i]
        pad = r + 3
        lo_x, hi_x = int(max(0, min(x0, x1) - pad)), int(min(w, max(x0, x1) + pad))
        lo_y, hi_y = int(max(0, min(y0, y1) - pad)), int(min(h, max(y0, y1) + pad))
        if lo_x >= hi_x or lo_y >= hi_y:
            continue
        sx = xs[lo_y:hi_y, lo_x:hi_x]; sy = ys[lo_y:hi_y, lo_x:hi_x]
        vx, vy = x1 - x0, y1 - y0
        L2 = vx * vx + vy * vy
        tt = 0.0 if L2 == 0 else np.clip(((sx - x0) * vx + (sy - y0) * vy) / L2, 0, 1)
        px, py = x0 + tt * vx, y0 + tt * vy
        seg = np.sqrt((sx - px) ** 2 + (sy - py) ** 2) - r
        np.minimum(d[lo_y:hi_y, lo_x:hi_x], seg, out=d[lo_y:hi_y, lo_x:hi_x])
    return d


def widths_for(n, w_mid, w_end):
    t = np.linspace(0, 1, n - 1)
    return w_end + (w_mid - w_end) * np.sin(np.pi * t) ** 0.45


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def ground(inner, outer):
    ys, xs = np.mgrid[0:W, 0:W].astype(np.float32) / W
    d = np.sqrt((xs - 0.5) ** 2 + (ys - 0.34) ** 2) / 0.95
    d = np.clip(d, 0, 1) ** 0.80
    a = np.array(inner, np.float32); b = np.array(outer, np.float32)
    return a + (b - a) * d[..., None]


def shade(d, base_hi, base_lo, edge):
    """Turn a distance field into a lit solid."""
    cov = smoothstep(1.5, -1.5, d)                   # anti-aliased coverage
    inner = np.clip(-d, 0, None)
    # body gradient: brighter at the top of the stroke
    ys = np.mgrid[0:W, 0:W][0].astype(np.float32) / W
    g = smoothstep(0.34, 0.66, ys)[..., None]
    body = np.array(base_hi, np.float32) * (1 - g) + np.array(base_lo, np.float32) * g
    # rim light along the upper edge -> dimensional
    rim = smoothstep(0.0, 26.0 * SS / 4, inner) * (1 - smoothstep(0, 34.0 * SS / 4, inner))
    gy = np.gradient(np.clip(d, -60, 60))[0]
    lit = np.clip(-gy, 0, None)
    lit = lit / (lit.max() + 1e-6)
    body = body + np.array(edge, np.float32) * (rim * lit * 1.5)[..., None]
    return body, cov


def blur(a, r):
    """Separable box blur, repeated - fast approximation of a gaussian."""
    k = int(r)
    if k < 1: return a
    out = a.astype(np.float32)
    for _ in range(3):
        c = np.cumsum(np.pad(out, ((k, k), (0, 0), (0, 0)), mode="edge"), 0)
        out = (c[2 * k:] - c[:-2 * k]) / (2 * k)
        c = np.cumsum(np.pad(out, ((0, 0), (k, k), (0, 0)), mode="edge"), 1)
        out = (c[:, 2 * k:] - c[:, :-2 * k]) / (2 * k)
    return out


def build(name, bg_in, bg_out, hotA, hotB, coolA, coolB, rim):
    n = 1400
    c_back, c_front = curve(math.pi), curve(0.0)
    w_back = widths_for(n, 96 * SS / 4, 30 * SS / 4)
    w_front = widths_for(n, 112 * SS / 4, 34 * SS / 4)

    d_back = sdf(c_back, w_back, (W, W))
    d_front = sdf(c_front, w_front, (W, W))

    img = ground(bg_in, bg_out)

    # glow beneath both ribbons
    glow_mask = np.minimum(d_back, d_front)
    gm = smoothstep(70.0 * SS / 4, -8.0, glow_mask)[..., None]
    glow_col = (np.array(hotA, np.float32) + np.array(coolA, np.float32)) / 2
    gl = blur(gm * glow_col, 26 * SS / 4)
    img = 255 - (255 - img) * (255 - np.clip(gl, 0, 255)) / 255      # screen

    # contact shadow, offset down
    sh = smoothstep(2.0, -2.0, np.minimum(d_back, d_front))[..., None]
    sh = np.roll(sh, int(14 * SS / 4), axis=0)
    sh = blur(sh, 14 * SS / 4)
    img = img * (1 - 0.68 * np.clip(sh, 0, 1))

    # back ribbon, then front - the overlap is what makes it interleave
    for d, hiA, hiB in ((d_back, coolA, coolB), (d_front, hotA, hotB)):
        body, cov = shade(d, hiA, hiB, rim)
        img = img * (1 - cov[..., None]) + body * cov[..., None]

    out = np.clip(img, 0, 255).astype(np.uint8)
    Image.fromarray(out).resize((S, S), Image.LANCZOS).save(name)
    print("wrote", name)


build("f_a.png", (26, 31, 50), (7, 8, 15),
      (150, 226, 255), (46, 116, 240), (86, 104, 255), (38, 40, 150), (210, 240, 255))
build("f_b.png", (44, 24, 52), (10, 6, 13),
      (255, 168, 214), (214, 44, 150), (152, 104, 255), (62, 30, 160), (255, 224, 245))
build("f_dark.png", (16, 18, 30), (3, 3, 6),
      (168, 232, 255), (40, 96, 210), (74, 88, 235), (26, 26, 120), (215, 240, 255))
build("f_c.png", (18, 40, 42), (5, 11, 12),
      (150, 255, 226), (26, 176, 150), (56, 168, 230), (18, 70, 140), (216, 255, 246))


# ---------------------------------------------------------------------------
# Install into the app bundle. Three variants, each at the sizes Info.plist and
# the asset catalog reference: 1024 for the catalog, 120 (@2x iPhone) and 152
# (@2x iPad) for the loose CFBundleIconFiles entries.
# ---------------------------------------------------------------------------
if __name__ == "__main__" and len(__import__("sys").argv) > 1 and __import__("sys").argv[1] == "install":
    import os, shutil
    from PIL import Image
    ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    VARIANTS = {
        # name        source render        catalog dir / filename                                  loose prefix
        "Light":  ("f_a.png", "AppIcon-Light.appiconset/1024x1024.png",                    "AppIcon-Light"),
        "Dark":   ("f_dark.png", "AppIcon-Dark.appiconset/AppIcon-Dark_1024x1024.png",        "AppIcon-Dark"),
        "Development": ("f_c.png", "AppIcon-Development.appiconset/AppIcon-Development_1024x1024.png", "AppIcon-Development"),
    }
    for label, (src, catalog, prefix) in VARIANTS.items():
        im = Image.open(src).convert("RGB")
        dst = os.path.join(ROOT, "Natives/Assets.xcassets", catalog)
        im.save(dst); print("  ", dst)
        for px, suffix in ((120, "60x60@2x.png"), (152, "76x76@2x~ipad.png")):
            out = os.path.join(ROOT, "Natives/resources", prefix + suffix)
            im.resize((px, px), Image.LANCZOS).save(out); print("  ", out)
    # the unprefixed pair is the primary icon
    im = Image.open("f_a.png").convert("RGB")
    for px, suffix in ((120, "60x60@2x.png"), (152, "76x76@2x~ipad.png")):
        out = os.path.join(ROOT, "Natives/resources", "AppIcon" + suffix)
        im.resize((px, px), Image.LANCZOS).save(out); print("  ", out)
