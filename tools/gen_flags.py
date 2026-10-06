#!/usr/bin/env python3
# Frontlines (working title) - nation flag generator.
# Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
# Based on OpenFront: (c) OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
# Flags: OpenFront (resources/flags), CC BY-SA 4.0 - attribution "OpenFront".
#
# Rasterizes every flag used by a nation in the maps listed in gen_catalog.py (the "flag" field of
# each OpenFront map manifest) to a small RGBA image and writes Luau modules:
#   Flags.lua        [ReplicatedStorage.Shared.Flags]       index: code -> chunk module
#   FlagsDataN.lua   [ReplicatedStorage.Shared.FlagsDataN]  base64 RGBA pixel data (each < ~190K chars)
# Like OpenFront's FlagAtlasArray, each flag is aspect-fitted (centred, not stretched) into a
# W x H cell with a transparent margin. Pixels are non-premultiplied RGBA, row-major.
# Usage: python3 gen_flags.py [--src DIR] [--maps DIR] [--out DIR] [--preview sheet.png]
# Never point --src at OpenFront's /proprietary folder.

import argparse
import base64
import io
import json
import os

import cairosvg
from PIL import Image

from gen_catalog import MAPS

W, H = 36, 24  # OpenFront's flag cell is 128x85 (~1.5:1)
RENDER = 288  # supersampling width before the downscale
CHUNK_LIMIT = 185_000  # characters of base64 per data module

HEADER = """--[[
	Frontlines (working title) - {what}
	Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
	Based on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
	Flags © OpenFront, CC BY-SA 4.0 (resources/flags), rasterized to {w}x{h} by gen_flags.py.
	GENERATED FILE - edit gen_flags.py and re-run it instead of editing this by hand.
]]
"""


def lua_str(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ord(ch) < 32:
            out.append("\\%d" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def flag_codes(maps_dir: str) -> list:
    codes = []
    for _, folder in MAPS:
        with open(os.path.join(maps_dir, folder, "manifest.json"), encoding="utf-8") as f:
            m = json.load(f)
        for n in m.get("nations", []):
            c = n.get("flag")
            if c and c not in codes:
                codes.append(c)
    return sorted(codes)


def render(path: str) -> Image.Image:
    with open(path, "rb") as f:
        svg = f.read()
    png = cairosvg.svg2png(bytestring=svg, output_width=RENDER)
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    if img.height > RENDER:  # tall flag: render by height instead
        png = cairosvg.svg2png(bytestring=svg, output_height=RENDER)
        img = Image.open(io.BytesIO(png)).convert("RGBA")
    return img


def fit(img: Image.Image) -> Image.Image:
    scale = min(W / img.width, H / img.height)
    w, h = max(1, round(img.width * scale)), max(1, round(img.height * scale))
    small = img.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.paste(small, ((W - w) // 2, (H - h) // 2))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/home/claude/ofr/resources/flags")
    ap.add_argument("--maps", default="/home/claude/ofr/resources/maps")
    ap.add_argument("--out", default=here)
    ap.add_argument("--preview", default=None)
    args = ap.parse_args()
    for d in (args.src, args.maps):
        if "proprietary" in os.path.abspath(d).split(os.sep):
            raise SystemExit("refusing to read OpenFront's proprietary assets")

    entries = []  # (code, b64, img)
    for code in flag_codes(args.maps):
        path = os.path.join(args.src, code + ".svg")
        if not os.path.exists(path):
            print("missing flag:", code)
            continue
        img = fit(render(path))
        entries.append((code, base64.b64encode(img.tobytes()).decode("ascii"), img))

    chunks, cur, cur_len = [], [], 0
    for e in entries:
        if cur and cur_len + len(e[1]) + len(e[0]) + 16 > CHUNK_LIMIT:
            chunks.append(cur)
            cur, cur_len = [], 0
        cur.append(e)
        cur_len += len(e[1]) + len(e[0]) + 16
    if cur:
        chunks.append(cur)

    index = []
    for i, chunk in enumerate(chunks, 1):
        lines = [HEADER.format(what=f"flag pixel data, part {i}.", w=W, h=H)]
        lines.append(f"-- ReplicatedStorage.Shared.FlagsData{i} (ModuleScript), required by Shared.Flags.\n")
        lines.append("return {")
        for code, b64, _ in chunk:
            lines.append(f'\t[{lua_str(code)}] = "{b64}",')
            index.append((code, i))
        lines.append("}\n")
        src = "\n".join(lines)
        assert len(src) < 190_000, f"FlagsData{i} too large ({len(src)})"
        with open(os.path.join(args.out, f"FlagsData{i}.lua"), "w", encoding="utf-8") as f:
            f.write(src)
    j = len(chunks) + 1
    while os.path.exists(os.path.join(args.out, f"FlagsData{j}.lua")):
        os.remove(os.path.join(args.out, f"FlagsData{j}.lua"))
        j += 1

    lines = [HEADER.format(what="flag index (OpenFront nation flags as raw pixels for EditableImage).", w=W, h=H)]
    lines.append(
        "-- ReplicatedStorage.Shared.Flags (ModuleScript). Children-free: the pixel data lives in the\n"
        "-- sibling modules Shared.FlagsData1..N (a script Source is limited to 200,000 characters).\n"
        "-- Flags.WIDTH, Flags.HEIGHT, Flags.CREDIT, Flags.has(code), Flags.get(code) -> base64 RGBA?\n"
        "-- Codes are the \"flag\" field of each nation in Shared.MapCatalog. Clients draw them with\n"
        "-- StarterPlayerScripts.FlagKit.\n"
    )
    lines.append("local Shared = script.Parent\n")
    lines.append("local Flags = {}")
    lines.append(f"Flags.WIDTH = {W}")
    lines.append(f"Flags.HEIGHT = {H}")
    lines.append('Flags.CREDIT = "Flags © OpenFront, CC BY-SA 4.0"\n')
    lines.append("-- code -> chunk index")
    lines.append("local INDEX = {")
    for code, i in index:
        lines.append(f"\t[{lua_str(code)}] = {i},")
    lines.append("}\n")
    lines.append(f"local CHUNKS = {len(chunks)}")
    lines.append("local loaded: { [number]: { [string]: string } } = {}\n")
    lines.append(
        "function Flags.has(code: string): boolean\n"
        "\treturn INDEX[code] ~= nil\n"
        "end\n\n"
        "function Flags.get(code: string): string?\n"
        "\tlocal i = INDEX[code]\n"
        "\tif not i or i > CHUNKS then\n"
        "\t\treturn nil\n"
        "\tend\n"
        "\tif not loaded[i] then\n"
        "\t\tlocal mod = Shared:WaitForChild(\"FlagsData\" .. i, 10)\n"
        "\t\tif not mod then\n"
        "\t\t\treturn nil\n"
        "\t\tend\n"
        "\t\tloaded[i] = require(mod) :: any\n"
        "\tend\n"
        "\treturn loaded[i][code]\n"
        "end\n\n"
        "return Flags\n"
    )
    with open(os.path.join(args.out, "Flags.lua"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    if args.preview:
        cols = 16
        rows = (len(entries) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * (W + 4), rows * (H + 4)), (60, 60, 60, 255))
        for k, (_, _, img) in enumerate(entries):
            sheet.alpha_composite(img, ((k % cols) * (W + 4) + 2, (k // cols) * (H + 4) + 2))
        sheet.save(args.preview)
    print(f"{len(entries)} flags in {len(chunks)} data module(s)")


if __name__ == "__main__":
    main()
