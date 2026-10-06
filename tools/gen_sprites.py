#!/usr/bin/env python3
# Frontlines (working title) - map sprite generator (unit sprites + name-plate status icons).
# Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
# Based on OpenFront: (c) OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
# Art: OpenFront resources/atlases/unit-atlas.png and status-atlas.png, CC BY-SA 4.0 -
# attribution "OpenFront".
#
# Writes Luau modules:
#   Sprites.lua        [ReplicatedStorage.Shared.Sprites]       index: name -> chunk, format, size
#   SpritesDataN.lua   [ReplicatedStorage.Shared.SpritesDataN]  base64 pixel data (each < ~190K chars)
#
# Unit sprites (OpenFront UnitPass): the unit atlas holds one 13x13 cell per unit type, drawn at
# 1 atlas pixel = 1 full-resolution tile. The grey levels are colour bands the shader replaces:
#   180 -> territory colour, 130 -> mix(territory, border), 100 -> centre (territory), 70 -> border,
#   255 -> white (shell / warhead). Each band is exported as its own 13x13 alpha mask
#   ("U<Unit><Band>", format "A") so the client can stack tinted ImageLabels.
# Status icons (OpenFront name pass, status-atlas.png: 256px cells, 16px padding) are exported as
# full-colour RGBA ("St<Name>"); the alliance icons get the dark outline the shader adds.
# Usage: python3 gen_sprites.py [--atlases DIR] [--out DIR] [--preview sheet.png]
# Never point --atlases at OpenFront's /proprietary folder.

import argparse
import base64
import json
import os

from PIL import Image, ImageChops, ImageFilter

CHUNK_LIMIT = 180_000
STATUS_SIZE = 64
GLOW_SIZE = 32

# atlas column -> unit name (UnitPass UNIT_ORDER)
UNITS = {
    0: "Transport",
    1: "TradeShip",
    2: "Warship",
    3: "AtomBomb",
    4: "HydrogenBomb",
    6: "SAMMissile",
    5: "MIRV",
    7: "Shell",
    8: "MIRVWarhead",
    9: "TrainEngine",
    10: "TrainCarriage",
    11: "TrainCarriageLoaded",
}


def band_of(r, g, b):
    # Exact grey bands first; anything else (the MIRV's red body) by the shader's thresholds
    # (unit.frag.glsl reads the red channel: > 0.6 territory, > 0.45 mid, > 0.34 centre, else border).
    for band, grey in BANDS.items():
        if abs(r - grey) <= 6 and r == g == b:
            return band
    v = r / 255
    return "A" if v > 0.6 else "M" if v > 0.45 else "C" if v > 0.34 else "B"
BANDS = {"A": 180, "M": 130, "C": 100, "B": 70, "W": 255}

STATUS = {
    "crown": "Crown",
    "traitor": "Traitor",
    "disconnected": "Disconnected",
    "alliance": "Alliance",
    "allianceRequest": "AllianceRequest",
    "target": "Target",
    "embargo": "Embargo",
    "nukeRed": "NukeRed",
    "nukeWhite": "NukeWhite",
    "allianceFaded": "AllianceFaded",
    "doomsdayClock": "Doomsday",
}
OUTLINED = {"alliance", "allianceFaded"}
OUTLINE_PX = 6  # render-settings.json name.statusOutlineWidth (atlas texels)

HEADER = """--[[
	Frontlines (working title) - {what}
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Sprites © OpenFront, CC BY-SA 4.0 (resources/atlases/unit-atlas.png, status-atlas.png),
	converted by gen_sprites.py.
	GENERATED FILE - edit gen_sprites.py and re-run it instead of editing this by hand.
]]
"""


def unit_entries(path):
    atlas = Image.open(path).convert("RGBA")
    cell = atlas.height
    out = []
    for col, name in UNITS.items():
        img = atlas.crop((col * cell, 0, (col + 1) * cell, cell))
        for band, grey in BANDS.items():
            mask = Image.new("L", img.size, 0)
            used = False
            for y in range(cell):
                for x in range(cell):
                    r, g, b, a = img.getpixel((x, y))
                    if a > 0 and band_of(r, g, b) == band:
                        mask.putpixel((x, y), a)
                        used = True
            if used:
                out.append(("U" + name + band, "A", mask, cell))
    return out


def outline(img, px):
    a = img.getchannel("A")
    ring = a.filter(ImageFilter.MaxFilter(px * 2 + 1))
    black = Image.new("RGBA", img.size, (0, 0, 0, 0))
    black.putalpha(ring)
    black.alpha_composite(img)
    return black


def status_entries(path, meta_path):
    atlas = Image.open(path).convert("RGBA")
    with open(meta_path) as f:
        meta = json.load(f)
    cell, cols, pad = meta["cellSize"], meta["cols"], meta["pad"]
    out = []
    for key, name in STATUS.items():
        idx = meta["icons"][key]
        x0, y0 = (idx % cols) * cell, (idx // cols) * cell
        img = atlas.crop((x0, y0, x0 + cell, y0 + cell))
        if key in OUTLINED:
            img = outline(img, OUTLINE_PX)
            # the outline may spill into the padding: keep a little of it
            crop = max(0, pad - OUTLINE_PX)
        else:
            crop = pad
        img = img.crop((crop, crop, cell - crop, cell - crop))
        size = round(STATUS_SIZE * img.width / (cell - 2 * pad))
        out.append(("St" + name, "RGBA", img.resize((size, size), Image.LANCZOS), size))
    return out


def glow_entry():
    # Hydrogen bomb halo (unit.frag.glsl): alpha = (1 - smoothstep(inner, 1, d)) * strength;
    # strength is applied by the client as transparency, so this is the falloff only.
    inner = 0.45
    img = Image.new("L", (GLOW_SIZE, GLOW_SIZE), 0)
    for y in range(GLOW_SIZE):
        for x in range(GLOW_SIZE):
            dx = (x + 0.5) / GLOW_SIZE - 0.5
            dy = (y + 0.5) / GLOW_SIZE - 0.5
            d = (dx * dx + dy * dy) ** 0.5 * 2
            t = min(1.0, max(0.0, (d - inner) / (1 - inner)))
            s = t * t * (3 - 2 * t)
            img.putpixel((x, y), int(round((1 - s) * 255)))
    return ("UGlow", "A", img, GLOW_SIZE)


def encode(img, fmt):
    if fmt == "A":
        return base64.b64encode(img.tobytes()).decode("ascii")
    return base64.b64encode(img.convert("RGBA").tobytes()).decode("ascii")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--atlases", default="/home/claude/ofr/resources/atlases")
    ap.add_argument("--out", default=here)
    ap.add_argument("--preview", default=None)
    args = ap.parse_args()
    if "proprietary" in os.path.abspath(args.atlases).split(os.sep):
        raise SystemExit("refusing to read OpenFront's proprietary assets")

    entries = unit_entries(os.path.join(args.atlases, "unit-atlas.png"))
    entries.append(glow_entry())
    entries += status_entries(
        os.path.join(args.atlases, "status-atlas.png"), os.path.join(args.atlases, "status-atlas-meta.json")
    )
    encoded = [(n, f, encode(img, f), s, img) for n, f, img, s in entries]

    chunks, cur, cur_len = [], [], 0
    for e in encoded:
        if cur and cur_len + len(e[2]) > CHUNK_LIMIT:
            chunks.append(cur)
            cur, cur_len = [], 0
        cur.append(e)
        cur_len += len(e[2]) + len(e[0]) + 16
    if cur:
        chunks.append(cur)

    for i, chunk in enumerate(chunks, 1):
        lines = [HEADER.format(what=f"map sprite pixel data, part {i}.")]
        lines.append(f"-- ReplicatedStorage.Shared.SpritesData{i} (ModuleScript), required by Shared.Sprites.\n")
        lines.append("return {")
        for name, _, b64, _, _ in chunk:
            lines.append(f'\t{name} = "{b64}",')
        lines.append("}\n")
        src = "\n".join(lines)
        assert len(src) < 190_000, f"SpritesData{i} too large ({len(src)})"
        with open(os.path.join(args.out, f"SpritesData{i}.lua"), "w") as f:
            f.write(src)
    j = len(chunks) + 1
    while os.path.exists(os.path.join(args.out, f"SpritesData{j}.lua")):
        os.remove(os.path.join(args.out, f"SpritesData{j}.lua"))
        j += 1

    idx = [HEADER.format(what="map sprite index (OpenFront unit sprites and status icons as raw pixels).")]
    idx.append("-- ReplicatedStorage.Shared.Sprites (ModuleScript). Children-free: the pixel data lives in the")
    idx.append("-- sibling modules Shared.SpritesData1..N (a script Source is limited to 200,000 characters).")
    idx.append("-- Sprites.has(name), Sprites.get(name) -> (format \"A\" | \"RGBA\", size, base64)?")
    idx.append("-- Square images. Clients draw them with StarterPlayerScripts.SpriteKit.\n")
    idx.append("local Shared = script.Parent\n")
    idx.append("local Sprites = {}")
    idx.append('Sprites.CREDIT = "Sprites © OpenFront, CC BY-SA 4.0"\n')
    idx.append("-- name -> { chunk index, format, size }")
    idx.append("local INDEX = {")
    for i, chunk in enumerate(chunks, 1):
        for name, fmt, _, size, _ in chunk:
            idx.append(f'\t{name} = {{ {i}, "{fmt}", {size} }},')
    idx.append("}\n")
    idx.append(f"local CHUNKS = {len(chunks)}")
    idx.append("local loaded: { [number]: { [string]: string } } = {}\n")
    idx.append("function Sprites.has(name: string): boolean")
    idx.append("\treturn INDEX[name] ~= nil")
    idx.append("end\n")
    idx.append("function Sprites.get(name: string): (string?, number?, string?)")
    idx.append("\tlocal e = INDEX[name]")
    idx.append("\tif not e or e[1] > CHUNKS then")
    idx.append("\t\treturn nil, nil, nil")
    idx.append("\tend")
    idx.append("\tlocal i = e[1]")
    idx.append("\tif not loaded[i] then")
    idx.append("\t\tlocal mod = Shared:WaitForChild(\"SpritesData\" .. i, 10)")
    idx.append("\t\tif not mod then")
    idx.append("\t\t\treturn nil, nil, nil")
    idx.append("\t\tend")
    idx.append("\t\tloaded[i] = require(mod) :: any")
    idx.append("\tend")
    idx.append("\treturn e[2], e[3], loaded[i][name]")
    idx.append("end\n")
    idx.append("return Sprites\n")
    with open(os.path.join(args.out, "Sprites.lua"), "w") as f:
        f.write("\n".join(idx))

    if args.preview:
        cell = STATUS_SIZE + 8
        cols = 10
        rows = (len(encoded) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell, rows * cell), (60, 110, 60, 255))
        for k, (_, fmt, _, size, img) in enumerate(encoded):
            if fmt == "A":
                rgba = Image.new("RGBA", img.size, (255, 255, 255, 0))
                rgba.putalpha(img)
                img = rgba
            scale = max(1, (STATUS_SIZE // img.width))
            big = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
            sheet.alpha_composite(big, ((k % cols) * cell + 4, (k // cols) * cell + 4))
        sheet.save(args.preview)
    print(f"{len(encoded)} sprites in {len(chunks)} data module(s)")


if __name__ == "__main__":
    main()
