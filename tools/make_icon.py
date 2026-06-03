#!/usr/bin/env python3
"""Generate the Loopback app icon (1024x1024, no alpha).

On-brand with the app's dark UI: a deep gradient background, a green recovery
ring (matching Theme.recoveryGreen), and a white heartbeat/ECG pulse line.
"""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersample factor for crisp anti-aliased edges
W = S * SS

img = Image.new("RGB", (W, W), (0, 0, 0))
px = img.load()

# --- Background: vertical gradient with a subtle teal tint, near-black bottom.
top = (0x16, 0x1E, 0x22)      # dark teal-charcoal
bot = (0x07, 0x07, 0x0A)      # near-black (Theme.bg)
for y in range(W):
    t = y / (W - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    for x in range(W):
        px[x, y] = (r, g, b)

draw = ImageDraw.Draw(img)
cx = cy = W / 2

# --- Soft green glow behind the ring.
glow = Image.new("RGB", (W, W), (0, 0, 0))
gdraw = ImageDraw.Draw(glow)
gr = W * 0.34
gdraw.ellipse([cx - gr, cy - gr, cx + gr, cy + gr], fill=(0x0E, 0x6E, 0x52))
glow = glow.filter(ImageFilter.GaussianBlur(W * 0.06))
img = Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.0)
# Additive-style blend: lighten background by the blurred glow.
base = img.load()
gl = glow.load()
for y in range(W):
    for x in range(W):
        br, bg, bb = base[x, y]
        rr, rg, rb = gl[x, y]
        base[x, y] = (min(255, br + rr // 3), min(255, bg + rg // 3), min(255, bb + rb // 3))

draw = ImageDraw.Draw(img)

GREEN = (0x12, 0xE2, 0x9A)
MINT = (0x6F, 0xFF, 0xCE)

# --- Recovery ring: a thick open arc (gap at the bottom), rounded ends.
ring_r = W * 0.30
ring_w = int(W * 0.075)
bbox = [cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r]
# Open arc from 125deg sweeping clockwise to 55deg (gap at bottom).
start_deg = 130
end_deg = 410  # 50 + 360
draw.arc(bbox, start=start_deg, end=end_deg, fill=GREEN, width=ring_w)

# Rounded caps on the arc ends.
def cap(angle_deg, color):
    a = math.radians(angle_deg)
    ex = cx + ring_r * math.cos(a)
    ey = cy + ring_r * math.sin(a)
    rr = ring_w / 2
    draw.ellipse([ex - rr, ey - rr, ex + rr, ey + rr], fill=color)

cap(start_deg, GREEN)
cap(end_deg, MINT)

# A small mint accent segment near the leading cap for depth.
draw.arc(bbox, start=end_deg - 55, end=end_deg, fill=MINT, width=ring_w)
cap(end_deg, MINT)

# --- Heartbeat / ECG pulse line across the middle.
midy = cy + W * 0.01
amp = W * 0.085
pts = [
    (cx - ring_r * 0.78, midy),
    (cx - ring_r * 0.30, midy),
    (cx - ring_r * 0.14, midy - amp * 0.45),
    (cx - ring_r * 0.02, midy + amp),
    (cx + ring_r * 0.14, midy - amp * 1.25),
    (cx + ring_r * 0.30, midy),
    (cx + ring_r * 0.80, midy),
]
lw = int(W * 0.030)
draw.line(pts, fill=(0xFF, 0xFF, 0xFF), width=lw, joint="curve")
# Rounded ends + vertices.
for p in pts:
    rr = lw / 2
    draw.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=(0xFF, 0xFF, 0xFF))

# --- Downsample for anti-aliasing.
out = img.resize((S, S), Image.LANCZOS)
out.save("Loopback/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", "PNG")
print("wrote AppIcon-1024.png")
