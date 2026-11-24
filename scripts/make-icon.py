#!/usr/bin/env python3
"""Generates Icon/Stereo.icon: two overlapping CDs on orange, as Icon Composer layers.

Run from the repo root: python3 scripts/make-icon.py
Preview any appearance with Icon Composer's ictool, for example:
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
    Icon/Stereo.icon --export-image --output-file out.png --platform macOS --rendition ClearDark \
    --width 512 --height 512 --scale 1
Renditions: Default, Dark, ClearLight, ClearDark, TintedLight, TintedDark.
"""
import json, math, os, shutil

W = 1024
OUT = "Icon/Stereo.icon"
ORANGE = "extended-srgb:1.00000,0.52000,0.10000,1.00000"
DARK_FILL = "extended-srgb:0.10000,0.07000,0.05000,1.00000"
# In dark mode the discs turn orange on a near-black fill, as Apple's own icons do.
LAYER_DARK = {"appearance": "dark", "value": {"solid": "extended-srgb:1.00000,0.60000,0.22000,1.00000"}}
# Colour would fight the user's tint, so the rainbow sheen is hidden in tinted and clear styles.
TINTED_HIDDEN = {"hidden-specializations": [{"appearance": "tinted", "value": True}]}


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">{body}</svg>'


def circle(cx, cy, r):
    return f"M{cx - r} {cy} a{r} {r} 0 1 0 {2 * r} 0 a{r} {r} 0 1 0 {-2 * r} 0Z "


def ring(cx, cy, inner, outer, opacity, fill="#fff"):
    return f'<path fill-rule="evenodd" fill="{fill}" fill-opacity="{opacity}" d="{circle(cx, cy, outer)}{circle(cx, cy, inner)}"/>'


def cd(cx, cy, r):
    """Real CD proportions (120 mm disc): 15 mm hole, clear hub, stacking ring, data from ~46 mm.
    No grooves: those read as vinyl."""
    return svg(
        ring(cx, cy, r * 0.38, r, 1.0)              # mirrored data area
        + ring(cx, cy, r * 0.125, r * 0.38, 0.38)   # clear plastic hub
        + ring(cx, cy, r * 0.27, r * 0.295, 0.7)    # stacking ring moulded into the hub
        + ring(cx, cy, r * 0.985, r, 0.5, "#000")   # thin outer edge
    )


def sheen(cx, cy, r):
    """A soft two-way sheen over the data area: cool on one side, warm on the other, clear between.
    Hard spectral bands looked garish at icon size."""
    gid = f"sheen{cx}"
    return svg(
        f'<defs><linearGradient id="{gid}" x1="{cx - r}" y1="{cy - r}" x2="{cx + r}" y2="{cy + r}" gradientUnits="userSpaceOnUse">'
        '<stop offset="0" stop-color="#7a6cff" stop-opacity="0.38"/>'
        '<stop offset="0.22" stop-color="#4fd2ff" stop-opacity="0.30"/>'
        '<stop offset="0.48" stop-color="#ffffff" stop-opacity="0"/>'
        '<stop offset="0.74" stop-color="#ffd25a" stop-opacity="0.30"/>'
        '<stop offset="1" stop-color="#ff6fae" stop-opacity="0.38"/>'
        '</linearGradient></defs>'
        f'<path fill-rule="evenodd" fill="url(#{gid})" d="{circle(cx, cy, r * 0.985)}{circle(cx, cy, r * 0.40)}"/>'
    )


# Top-most first: the front disc lower right, the back disc upper left and dimmer.
LAYERS = [
    ("sheen", sheen(590, 590, 270), dict(glass=False, **TINTED_HIDDEN)),
    ("front", cd(590, 590, 270), {"glass": True, "fill-specializations": [LAYER_DARK]}),
    ("back-sheen", sheen(420, 420, 270), dict(glass=False, opacity=0.6, **TINTED_HIDDEN)),
    ("back", cd(420, 420, 270), {"glass": True, "opacity": 0.6, "fill-specializations": [LAYER_DARK]}),
]

if __name__ == "__main__":
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(f"{OUT}/Assets")
    layers = []
    for name, content, extra in LAYERS:
        with open(f"{OUT}/Assets/{name}.svg", "w") as f:
            f.write(content)
        layers.append({"image-name": f"{name}.svg", "name": name, **extra})
    icon = {
        "fill-specializations": [
            {"value": {"automatic-gradient": ORANGE}},
            {"appearance": "dark", "value": {"automatic-gradient": DARK_FILL}},
        ],
        "groups": [{"layers": layers, "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": True, "value": 0.4}}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    with open(f"{OUT}/icon.json", "w") as f:
        json.dump(icon, f, indent=2)
    print(f"wrote {OUT}")
