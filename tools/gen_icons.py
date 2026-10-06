#!/usr/bin/env python3
# Frontlines (working title) - icon generator.
# Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
# Icons: OpenFront (resources/images), CC BY-SA 4.0 - attribution "OpenFront".
#
# Rasterizes chosen OpenFront SVG icons to 48x48 and writes Luau modules:
#   Icons.lua        [ReplicatedStorage.Shared.Icons]       index: name -> chunk module, format
#   IconsDataN.lua   [ReplicatedStorage.Shared.IconsDataN]  base64 pixel data (each < ~190K chars)
# Formats: "A" = 8-bit alpha only (white glyph, tint with ImageColor3),
#          "RGBA" = full colour (non-premultiplied, row-major).
# Usage: python3 gen_icons.py [--src DIR] [--out DIR] [--preview sheet.png]
# Never point --src at OpenFront's /proprietary folder.

import argparse
import base64
import io
import math
import os
import re

import cairosvg
from PIL import Image, ImageDraw

SIZE = 48
PAD = 2  # transparent margin around the glyph
RENDER = 384  # supersampling size before the downscale
CHUNK_LIMIT = 185_000  # characters of base64 per data module

# name: (svg file, mode, extra)   mode "white" forces a white glyph, "color" keeps the colours.
ICONS = {
    "City": ("CityIconWhite.svg", "white", {}),
    "Port": ("TradingIconWhite.svg", "white", {}),
    "Defense": ("ShieldIconWhite.svg", "white", {}),
    "Silo": ("MissileSiloIconWhite.svg", "white", {}),
    "SAM": ("SamLauncherIconWhite.svg", "white", {}),
    "AtomBomb": ("NukeIconWhite.svg", "white", {}),
    "HBomb": ("MushroomCloudIconWhite.svg", "white", {}),
    "Warship": ("BattleshipIconWhite.svg", "white", {}),
    "TradeShip": ("TradeShipIconWhite.svg", "white", {}),
    "Boat": ("BoatIconWhite.svg", "white", {}),
    "Gold": ("GoldCoinIcon.svg", "white", {}),
    "Troops": ("TroopIconWhite.svg", "white", {}),
    "Alliance": ("AllianceIconWhite.svg", "white", {}),
    "Traitor": ("TraitorIconWhite.svg", "white", {}),
    "Embargo": ("EmbargoWhiteIcon.svg", "white", {}),
    "Target": ("TargetIconWhite.svg", "white", {}),
    "Sword": ("SwordIconWhite.svg", "white", {}),
    "Leaderboard": ("LeaderboardIconSolidWhite.svg", "white", {}),
    "Settings": ("SettingIconWhite.svg", "white", {}),
    "Info": ("InfoIconSolidWhite.svg", "white", {}),
    "DonateGold": ("DonateGoldIconWhite.svg", "white", {}),
    "DonateTroops": ("DonateTroopIconWhite.svg", "white", {}),
    "Close": ("XIcon.svg", "white", {"viewBox": "0 0 100 100"}),  # drop the attribution text
    "Crown": ("CrownIcon.svg", "color", {}),
    "Explosion": ("ExplosionIconWhite.svg", "white", {}),
    "Land": ("ClaimIcon.svg", "white", {}),
    # Radial menu / attacks display (interact feature)
    "Build": ("BuildIconWhite.svg", "white", {}),
    "Emoji": ("EmojiIconWhite.svg", "white", {}),
    "Back": ("BackIconWhite.svg", "white", {}),
    "Soldier": ("SoldierIcon.svg", "white", {}),
    # In-match HUD parity (ui_hud wave 7): unit display / build menu / sidebars / player panel
    "Factory": ("FactoryIconWhite.svg", "white", {}),
    "MIRV": ("MIRVIcon.svg", "white", {}),
    "Chat": ("ChatIconWhite.svg", "white", {}),
    "Exit": ("ExitIconWhite.svg", "white", {}),
    "LeaderboardRegular": ("LeaderboardIconRegularWhite.svg", "white", {}),
    "Tree": ("TreeIconWhite.svg", "white", {}),
    "UpperLimit": ("UpperLimitIcon.svg", "white", {}),
    "Profile": ("ProfileIcon.svg", "white", {}),
    "Stop": ("StopIconWhite.svg", "white", {}),
    # Team games: GameLeftSidebar team-stats toggle
    "Team": ("TeamIconSolidWhite.svg", "white", {}),
    "TeamRegular": ("TeamIconRegularWhite.svg", "white", {}),
}

# Map-marker art (MapMarkers.lua), mirroring OpenFront's structure shader
# (src/client/render/gl/shaders/structure/structure.frag.glsl + render-settings.json "structure"):
# each structure is a shape (circumradius 0.45 of its quad) with a dark border band, and a white
# glyph from OpenFront's resources/atlases/icon-atlas.png (64px cells, CC BY-SA 4.0).
#   Mk<Kind>    full shape mask (tinted with the border colour)
#   Mk<Kind>In  shape minus the border band (tinted with the fill colour)
#   MkIcon<Kind> the atlas glyph cell, uncropped (the glyph keeps the atlas cell's padding)
# kind: (atlas column, sides (0 = circle), rotation, shape scale)
MARKER_SHAPES = {
    "City": (0, 0, 0.0, 1.0),
    "Port": (1, 5, math.pi * 0.5, 1.08),
    "Defense": (3, 8, 0.0, 1.0),
    "SAM": (4, 4, 0.0, 1.4),
    "Silo": (5, 3, math.pi * 0.5, 1.55),
    "Factory": (2, 6, math.pi / 6, 1.08),  # structure.frag.glsl: hexagon, flat top
}
MARKER_RADIUS = 0.45
MARKER_BORDER = 0.06  # divided by the shape scale, like the shader
ATLAS_CELL = 64


def shape_mask(sides: int, rot: float, inset: float) -> Image.Image:
    big = RENDER
    img = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(img)
    c = big / 2
    if sides == 0:
        r = (MARKER_RADIUS - inset) * big
        d.ellipse((c - r, c - r, c + r, c + r), fill=255)
    else:
        an = math.pi / sides
        apothem = MARKER_RADIUS * math.cos(an) - inset
        R = apothem / math.cos(an) * big
        # Edge midpoints sit at rot + 2k*an (sdPolygon), so the vertices sit half way between.
        pts = [(c + R * math.cos(rot + an + 2 * an * k), c + R * math.sin(rot + an + 2 * an * k)) for k in range(sides)]
        d.polygon(pts, fill=255)
    small = img.resize((SIZE, SIZE), Image.LANCZOS)
    white = Image.new("L", (SIZE, SIZE), 255)
    return Image.merge("RGBA", (white, white, white, small))


def marker_entries(atlas_path: str):
    out = []
    atlas = Image.open(atlas_path).convert("RGBA")
    for kind, (col, sides, rot, scale) in MARKER_SHAPES.items():
        out.append(("Mk" + kind, shape_mask(sides, rot, 0.0)))
        out.append(("Mk" + kind + "In", shape_mask(sides, rot, MARKER_BORDER / scale)))
        cell = atlas.crop((col * ATLAS_CELL, 0, (col + 1) * ATLAS_CELL, ATLAS_CELL)).resize((SIZE, SIZE), Image.LANCZOS)
        alpha = cell.getchannel("A")
        white = Image.new("L", (SIZE, SIZE), 255)
        out.append(("MkIcon" + kind, Image.merge("RGBA", (white, white, white, alpha))))
    return out


HEADER = """--[[
	Frontlines (working title) - {what}
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Icons © OpenFront, CC BY-SA 4.0 (resources/images), rasterized to {size}x{size} by icons/gen_icons.py.
	GENERATED FILE - edit gen_icons.py and re-run it instead of editing this by hand.
]]
"""


def render(path: str, extra: dict) -> Image.Image:
    with open(path, "rb") as f:
        svg = f.read().decode("utf-8")
    vb = extra.get("viewBox")
    if vb:
        svg = re.sub(r'viewBox="[^"]*"', f'viewBox="{vb}"', svg, count=1)
        _, _, w, h = (float(v) for v in vb.split())
        # Drop explicit width/height so the new viewBox drives the aspect ratio.
        svg = re.sub(r'(<svg[^>]*?)\s(width|height)="[^"]*"', r"\1", svg, count=2)
    png = cairosvg.svg2png(bytestring=svg.encode("utf-8"), output_width=RENDER)
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    if img.height > RENDER * 2:  # very tall icon: re-render by height instead
        png = cairosvg.svg2png(bytestring=svg.encode("utf-8"), output_height=RENDER)
        img = Image.open(io.BytesIO(png)).convert("RGBA")
    return img


def fit(img: Image.Image) -> Image.Image:
    bbox = img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if bbox:
        img = img.crop(bbox)
    inner = SIZE - 2 * PAD
    scale = inner / max(img.width, img.height)
    w, h = max(1, round(img.width * scale)), max(1, round(img.height * scale))
    small = img.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(small, ((SIZE - w) // 2, (SIZE - h) // 2))
    return out


def encode(img: Image.Image, mode: str):
    if mode == "white":
        return "A", base64.b64encode(img.getchannel("A").tobytes()).decode("ascii")
    return "RGBA", base64.b64encode(img.tobytes()).decode("ascii")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/home/claude/ofr/resources/images")
    ap.add_argument("--atlas", default="/home/claude/ofr/resources/atlases/icon-atlas.png")
    ap.add_argument("--out", default=here)
    ap.add_argument("--preview", default=None)
    args = ap.parse_args()
    if "proprietary" in os.path.abspath(args.src).split(os.sep) or "proprietary" in os.path.abspath(args.atlas).split(os.sep):
        raise SystemExit("refusing to read OpenFront's proprietary assets")

    entries = []  # (name, fmt, b64, img)
    for name, (file, mode, extra) in ICONS.items():
        img = fit(render(os.path.join(args.src, file), extra))
        if mode == "white":
            alpha = img.getchannel("A")
            img = Image.merge("RGBA", (*Image.new("RGB", img.size, (255, 255, 255)).split(), alpha))
        fmt, b64 = encode(img, mode)
        entries.append((name, fmt, b64, img))
    for name, img in marker_entries(args.atlas):
        fmt, b64 = encode(img, "white")
        entries.append((name, fmt, b64, img))

    # Split into data chunks.
    chunks, cur, cur_len = [], [], 0
    for e in entries:
        if cur and cur_len + len(e[2]) > CHUNK_LIMIT:
            chunks.append(cur)
            cur, cur_len = [], 0
        cur.append(e)
        cur_len += len(e[2]) + len(e[0]) + 16
    if cur:
        chunks.append(cur)

    for i, chunk in enumerate(chunks, 1):
        lines = [HEADER.format(what=f"icon pixel data, part {i}.", size=SIZE)]
        lines.append(f"-- ReplicatedStorage.Shared.IconsData{i} (ModuleScript), required by Shared.Icons.\n")
        lines.append("return {")
        for name, fmt, b64, _ in chunk:
            lines.append(f'\t{name} = "{b64}",')
        lines.append("}\n")
        src = "\n".join(lines)
        assert len(src) < 199_000, f"IconsData{i} too large ({len(src)})"
        with open(os.path.join(args.out, f"IconsData{i}.lua"), "w") as f:
            f.write(src)
    # Remove stale chunk files from a previous, larger run.
    j = len(chunks) + 1
    while os.path.exists(os.path.join(args.out, f"IconsData{j}.lua")):
        os.remove(os.path.join(args.out, f"IconsData{j}.lua"))
        j += 1

    idx = [HEADER.format(what="icon index (OpenFront icons as raw pixels for EditableImage).", size=SIZE)]
    idx.append("-- ReplicatedStorage.Shared.Icons (ModuleScript). Children-free: the pixel data lives in the")
    idx.append("-- sibling modules Shared.IconsData1..N (a script Source is limited to 200,000 characters).")
    idx.append("-- Icons.SIZE, Icons.CREDIT, Icons.has(name), Icons.get(name) -> (format \"A\" | \"RGBA\", base64)?")
    idx.append("-- Clients draw them with StarterPlayerScripts.IconKit.\n")
    idx.append('local Shared = script.Parent\n')
    idx.append("local Icons = {}")
    idx.append(f"Icons.SIZE = {SIZE}")
    idx.append('Icons.CREDIT = "Icons © OpenFront, CC BY-SA 4.0"\n')
    idx.append("-- name -> { chunk index, format }")
    idx.append("local INDEX = {")
    for i, chunk in enumerate(chunks, 1):
        for name, fmt, _, _ in chunk:
            idx.append(f'\t{name} = {{ {i}, "{fmt}" }},')
    idx.append("}\n")
    idx.append(f"local CHUNKS = {len(chunks)}")
    idx.append("local loaded: { [number]: { [string]: string } } = {}\n")
    idx.append("function Icons.has(name: string): boolean")
    idx.append("\treturn INDEX[name] ~= nil")
    idx.append("end\n")
    idx.append("function Icons.get(name: string): (string?, string?)")
    idx.append("\tlocal e = INDEX[name]")
    idx.append("\tif not e then")
    idx.append("\t\treturn nil, nil")
    idx.append("\tend")
    idx.append("\tlocal i = e[1]")
    idx.append("\tif not loaded[i] then")
    idx.append("\t\tlocal mod = Shared:WaitForChild(\"IconsData\" .. i, 10)")
    idx.append("\t\tif not mod or i > CHUNKS then")
    idx.append("\t\t\treturn nil, nil")
    idx.append("\t\tend")
    idx.append("\t\tloaded[i] = require(mod) :: any")
    idx.append("\tend")
    idx.append("\treturn e[2], loaded[i][name]")
    idx.append("end\n")
    idx.append("return Icons\n")
    with open(os.path.join(args.out, "Icons.lua"), "w") as f:
        f.write("\n".join(idx))

    if args.preview:
        cell = SIZE + 8
        cols = 9
        rows = (len(entries) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell * 2, rows * cell * 2), (20, 28, 44, 255))
        for k, (_, _, _, img) in enumerate(entries):
            big = img.resize((SIZE * 2, SIZE * 2), Image.NEAREST)
            x, y = (k % cols) * cell * 2 + 8, (k // cols) * cell * 2 + 8
            sheet.alpha_composite(big, (x, y))
        sheet.save(args.preview)

    total = sum(len(e[2]) for e in entries)
    print(f"{len(entries)} icons, {len(chunks)} data module(s), {total} base64 chars")


if __name__ == "__main__":
    main()
