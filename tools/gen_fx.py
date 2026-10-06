#!/usr/bin/env python3
# Frontlines (working title) - map effect sprite generator.
# Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
# Sprites: OpenFront (resources/sprites), CC BY-SA 4.0 - attribution "OpenFront".
#
# Packs OpenFront's animated FX sprite strips (the same sheets their fx atlas is built from) into
#   FxSprites.lua   [StarterPlayer.StarterPlayerScripts.FxSprites]
# Each sheet is stored palette-indexed: `pal` is a list of packed RGBA (r + g*2^8 + b*2^16 + a*2^24,
# the little-endian u32 EditableImage expects) and `px` is one character per pixel, row-major,
# where string.byte(px, i) - 48 is a 0-based index into `pal`. Frames sit side by side.
# Frame sizes / counts / durations follow OpenFront's FxSpritePass FX_CONFIG
# (src/client/render/gl/passes/fx-pass/FxSpritePass.ts, AGPL-3.0).
# Usage: python3 gen_fx.py [--src DIR] [--out DIR]
# Never point --src at OpenFront's /proprietary folder.

import argparse
import os

from PIL import Image

# name: (file, frame width, frame count, frame ms, looping)
SPRITES = {
    "Nuke": ("nukeExplosion.png", 60, 9, 70, False),
    "SamExplosion": ("samExplosion.png", 48, 9, 70, False),
    "BuildingExplosion": ("buildingExplosion.png", 17, 10, 70, False),
    "UnitExplosion": ("unitExplosion.png", 19, 4, 70, False),
    "MiniExplosion": ("miniExplosion.png", 13, 4, 70, False),
    "SinkingShip": ("sinkingShip.png", 16, 14, 90, False),
    "MiniFire": ("minifire.png", 7, 6, 100, True),
    "MiniSmoke": ("smoke.png", 11, 4, 120, True),
    "MiniBigSmoke": ("bigsmoke.png", 24, 5, 120, True),
    "MiniSmokeFire": ("smokeAndFire.png", 24, 5, 120, True),
    "Conquest": ("conquestSword.png", 21, 10, 90, False),
}

HEADER = """--[[
	Frontlines (working title) - map effect sprites (explosions, smoke, fire, sinking ship, conquest sword).
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Sprites © OpenFront, CC BY-SA 4.0 (resources/sprites), packed by gen_fx.py; frame timings from
	src/client/render/gl/passes/fx-pass/FxSpritePass.ts (AGPL-3.0).
	GENERATED FILE - edit gen_fx.py and re-run it instead of editing this by hand.
]]

-- StarterPlayer.StarterPlayerScripts.FxSprites (ModuleScript), used by MapFx.
-- FxSprites[name] = { w = frame width, h = height, n = frames, ms = frame duration, loop = bool,
--                     pal = { packed RGBA }, px = "<one char per pixel, byte - 48 = pal index>" }
"""


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/home/claude/ofr/resources/sprites")
    ap.add_argument("--out", default=here)
    args = ap.parse_args()
    if "proprietary" in os.path.abspath(args.src).split(os.sep):
        raise SystemExit("refusing to read OpenFront's proprietary assets")

    lines = [HEADER, "return {"]
    for name, (file, fw, n, ms, loop) in SPRITES.items():
        img = Image.open(os.path.join(args.src, file)).convert("RGBA")
        w, h = fw * n, img.height
        assert img.width >= w, f"{file}: sheet narrower than {n} frames"
        img = img.crop((0, 0, w, h))
        pal, chars = [], []
        for y in range(h):
            for x in range(w):
                r, g, b, a = img.getpixel((x, y))
                if a == 0:
                    r = g = b = 0
                packed = r + g * 256 + b * 65536 + a * 16777216
                if packed not in pal:
                    pal.append(packed)
                idx = pal.index(packed)
                assert idx < 70, f"{file}: too many colours"
                chars.append(chr(48 + idx))
        px = "".join(chars)
        assert '"' not in px and "\\" not in px
        pal_src = ", ".join(str(p) for p in pal)
        lines.append(
            f'\t{name} = {{ w = {fw}, h = {h}, n = {n}, ms = {ms}, loop = {"true" if loop else "false"}, '
            f'pal = {{ {pal_src} }}, px = "{px}" }},'
        )
    lines.append("}\n")
    src = "\n".join(lines)
    assert len(src) < 190_000, f"FxSprites too large ({len(src)})"
    with open(os.path.join(args.out, "FxSprites.lua"), "w") as f:
        f.write(src)
    print(f"FxSprites.lua: {len(src)} chars")


if __name__ == "__main__":
    main()
