#!/usr/bin/env python3
"""Ruler: measure UI spacing on an Android screenshot and draw the guides.

Each box is found from a seed point you place on the element's plain fill, not on
its text. Gaps are reported against the screen edges and the system bars, and
between neighboring boxes, in px and dp.

    ruler.py --adb emulator-5556 --box drawer=300,900 --out drawer.png
    ruler.py shot.png --density 2.625 --safe 63,1684 --box a=1100,1612 --box b=1700,1612

With --adb it takes the screenshot and reads the density and system bar insets from
the device itself. Needs Pillow.
"""
import argparse
import io
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

RED = (255, 48, 48)
YELLOW = (255, 214, 0)
CYAN = (0, 220, 255)


def adb(serial, *args):
    return subprocess.run(["adb", "-s", serial, *args], check=True, capture_output=True).stdout


def from_device(serial):
    img = Image.open(io.BytesIO(adb(serial, "exec-out", "screencap", "-p"))).convert("RGB")
    out = adb(serial, "shell", "wm", "density").decode()
    dpi = int(re.findall(r"density: (\d+)", out)[-1])  # the override, if any, comes last
    win = adb(serial, "shell", "dumpsys", "window").decode()
    top, bottom = 0, img.height

    def frame(kind):
        m = re.search(r"type=%s frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]" % kind, win)
        return tuple(map(int, m.groups())) if m else None

    sb = frame("statusBars")
    if sb and sb[1] == 0:
        top = sb[3]
    nb = frame("navigationBars")
    if nb and nb[3] == img.height:
        bottom = nb[1]
    return img, dpi / 160, top, bottom


def differs(a, b, tol):
    return sum(abs(a[i] - b[i]) for i in range(3)) > tol


MARK = (255, 0, 255)


def find_box(img, x, y, tol):
    # Flood the element's fill from the seed. Text and icons inside are islands the
    # fill flows around. The flood can also slip into a neighbor of the same color that
    # touches the element (a translucent panel over a list does this), so the box keeps
    # only the core of rows and columns at least half as full as the fullest one. That
    # core misses a pill's rounded ends, so it is then stretched along its middle row
    # and column for as long as the flood goes.
    work = img.copy()
    ImageDraw.floodfill(work, (x, y), MARK, thresh=tol)
    px, W, H = work.load(), work.width, work.height
    cols, rows = [0] * W, [0] * H
    for yy in range(H):
        for xx in range(W):
            if px[xx, yy] == MARK:
                cols[xx] += 1
                rows[yy] += 1
    xs = [i for i, n in enumerate(cols) if n >= max(cols) / 2]
    ys = [i for i, n in enumerate(rows) if n >= max(rows) / 2]
    l, r, t, b = xs[0], xs[-1], ys[0], ys[-1]
    cx, cy = (l + r) // 2, (t + b) // 2
    while l > 0 and px[l - 1, cy] == MARK:
        l -= 1
    while r < W - 1 and px[r + 1, cy] == MARK:
        r += 1
    while t > 0 and px[cx, t - 1] == MARK:
        t -= 1
    while b < H - 1 and px[cx, b + 1] == MARK:
        b += 1
    # The flood stops at a border or an anti-aliased rim. Push each side out over those
    # pixels until three in a row are alike, which means we are outside. A border can be
    # two pixels of one color, so two alike is not enough.
    src = img.load()

    def grow(edge, step, sample):
        at = lambda k: sample(edge + step * k)
        for k in range(1, 9):
            if not differs(at(k), at(k + 1), 4) and not differs(at(k + 1), at(k + 2), 4):
                return edge + step * (k - 1)
        return edge

    clampx = lambda v: max(0, min(img.width - 1, v))
    clampy = lambda v: max(0, min(img.height - 1, v))
    l = grow(l, -1, lambda v: src[clampx(v), cy])
    r = grow(r, 1, lambda v: src[clampx(v), cy])
    t = grow(t, -1, lambda v: src[cx, clampy(v)])
    b = grow(b, 1, lambda v: src[cx, clampy(v)])
    return l, t, r, b  # inclusive


def font(size):
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?", help="screenshot PNG (or use --adb)")
    ap.add_argument("--adb", metavar="SERIAL", help="take the screenshot from this device")
    ap.add_argument("--density", type=float, help="px per dp, e.g. 2.625 for 420dpi")
    ap.add_argument("--safe", help="TOP,BOTTOM: first row below the status bar, first row of the navigation bar")
    ap.add_argument("--box", action="append", default=[], metavar="NAME=X,Y", help="seed a box to measure")
    ap.add_argument("--tol", type=int, default=8, help="color difference that counts as an edge")
    ap.add_argument("--out", default="ruler.png")
    a = ap.parse_args()

    if a.adb:
        img, density, top, bottom = from_device(a.adb)
    elif a.image:
        img = Image.open(a.image).convert("RGB")
        density, top, bottom = 1.0, 0, img.height
    else:
        ap.error("give a screenshot or --adb")
    if a.density:
        density = a.density
    if a.safe:
        top, bottom = map(int, a.safe.split(","))
    W, H = img.size
    dp = lambda v: f"{v}px = {v / density:.1f}dp"

    boxes = []
    for spec in a.box:
        name, xy = spec.split("=")
        x, y = map(int, xy.split(","))
        boxes.append((name, find_box(img, x, y, a.tol)))

    draw = ImageDraw.Draw(img)
    f = font(max(18, W // 70))

    def label(xy, text, fill, anchor):
        # Nudge a label back inside the image when its anchor sits near an edge.
        x0, y0, x1, y1 = draw.textbbox(xy, text, font=f, anchor=anchor)
        dx = max(0, 4 - x0) - max(0, x1 - (W - 4))
        dy = max(0, 4 - y0) - max(0, y1 - (H - 4))
        draw.text((xy[0] + dx, xy[1] + dy), text, fill=fill, font=f, anchor=anchor)
    for x in range(0, W, 24):
        if top > 0:
            draw.line([(x, top), (x + 12, top)], fill=YELLOW, width=3)
        if bottom < H:
            draw.line([(x, bottom), (x + 12, bottom)], fill=YELLOW, width=3)

    print(f"screen {W}x{H}, {density:g} px/dp, safe rows {top}..{bottom - 1}")
    for name, (l, t, r, b) in boxes:
        w, h = r - l + 1, b - t + 1
        gaps = {"left": l, "right": W - 1 - r, "top": t - top, "bottom": bottom - 1 - b}
        print(f"{name}: x {l}..{r}, y {t}..{b}, {dp(w)} wide, {dp(h)} tall")
        print("   " + ", ".join(f"{k} {dp(v)}" for k, v in gaps.items()))
        draw.rectangle([l, t, r, b], outline=RED, width=3)
        name_text = f"{name} {w / density:.1f}x{h / density:.1f}dp"
        if h > 4 * f.size:
            label((l + 8, b - 8), name_text, CYAN, "ld")
        else:
            label((l, t - 6), name_text, CYAN, "ld")
        cx, cy = (l + r) // 2, (t + b) // 2
        others = [bx for n, bx in boxes if n != name]
        for (x0, y0, x1, y1), v in (
            ((cx, top, cx, t), gaps["top"]),
            ((cx, b, cx, bottom), gaps["bottom"]),
            ((0, cy, l, cy), gaps["left"]),
            ((r, cy, W - 1, cy), gaps["right"]),
        ):
            # A gap to the screen edge that runs through another box says nothing useful.
            if v <= 0 or any(min(x0, x1) <= o[2] and max(x0, x1) >= o[0] and min(y0, y1) <= o[3] and max(y0, y1) >= o[1] for o in others):
                continue
            draw.line([(x0, y0), (x1, y1)], fill=RED, width=3)
            if x0 == x1:
                label((x0 + 8, (y0 + y1) // 2), f"{v / density:.1f}dp", RED, "lm")
            else:
                label(((x0 + x1) // 2, y0 - 6), f"{v / density:.1f}dp", RED, "md")

    # Neighbors side by side: the gap between them and whether they share a width.
    for (na, (al, at, ar, ab)), (nb, (bl, bt, br, bb)) in zip(boxes, boxes[1:]):
        if bl > ar:
            g, y = bl - ar - 1, (max(at, bt) + min(ab, bb)) // 2
            draw.line([(ar, y), (bl, y)], fill=YELLOW, width=3)
            label(((ar + bl) // 2, y - 8), f"{g / density:.1f}dp", YELLOW, "md")
            print(f"{na} to {nb}: {dp(g)} apart, widths {ar - al + 1} vs {br - bl + 1}px")
        elif bt > ab:
            g, x = bt - ab - 1, (max(al, bl) + min(ar, br)) // 2
            draw.line([(x, ab), (x, bt)], fill=YELLOW, width=3)
            label((x + 8, (ab + bt) // 2), f"{g / density:.1f}dp", YELLOW, "lm")
            print(f"{na} to {nb}: {dp(g)} apart, heights {ab - at + 1} vs {bb - bt + 1}px")

    img.save(a.out)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    sys.exit(main())
