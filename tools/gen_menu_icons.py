#!/usr/bin/env python3
# War Front - main menu icon generator.
# Copyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.
# Based on OpenFront: (c) OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO
# The stroke icons below are the inline SVGs of OpenFront's home screen (NavUtilityIcons.ts,
# ModalHeader.ts, GameModeSelector.ts, LobbyCard.ts, UsernameInput.ts, PlayPage.ts; AGPL-3.0).
# GitHub mark and the UK/US language flag come from OpenFront resources/ (CC BY-SA 4.0 /
# trademark of GitHub, used only as a link icon).
#
# Writes MenuIconsData.lua [StarterPlayer.StarterPlayerScripts.MenuIconsData] with 48x48 icons:
#   "A"    = 8-bit alpha (white glyph, tint with ImageColor3)
#   "RGBA" = full colour (non-premultiplied, row-major)
# Usage: python3 gen_menu_icons.py [--ofr /home/claude/ofr] [--out MenuIconsData.lua]
# Never point --ofr at OpenFront's /proprietary folder.

import argparse
import base64
import io
import os

import cairosvg
from PIL import Image

SIZE = 48
RENDER = 384


def stroke_svg(body, view="0 0 24 24", width="1.8", fill="none"):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" fill="{fill}" '
        f'stroke="white" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round">'
        f"{body}</svg>"
    )


def fill_svg(body, view="0 0 20 20"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" fill="white">{body}</svg>'


INLINE = {
    # NavUtilityIcons.ts
    "Bell": stroke_svg('<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9" /><path d="M13.73 21a2 2 0 0 1-3.46 0" />'),
    "Help": stroke_svg('<circle cx="12" cy="12" r="9" /><path d="M9.2 9.2a2.9 2.9 0 0 1 5.6 1c0 1.9-2.8 2.4-2.8 4" /><line x1="12" y1="17.5" x2="12.01" y2="17.5" />'),
    "Gear": stroke_svg(
        '<circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z" />'
    ),
    # PlayPage.ts hamburger
    "Menu": stroke_svg('<path d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5" />', width="1.5"),
    # ModalHeader.ts back arrow
    "Back": stroke_svg('<path d="M10 19l-7-7m0 0l7-7m-7 7h18" />', width="2"),
    # GameModeSelector.ts "see all" chevron
    "Chevron": fill_svg('<path fill-rule="evenodd" d="M8.22 5.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L11.94 10 8.22 6.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />'),
    # UsernameInput.ts clan tag caret
    "Caret": stroke_svg('<path d="M5.5 7.5 10 12l4.5-4.5" />', view="0 0 20 20", width="2"),
    # LobbyCard.ts player count
    "People": fill_svg('<path d="M13 6a3 3 0 11-6 0 3 3 0 016 0zM18 8a2 2 0 11-4 0 2 2 0 014 0zM14 15a4 4 0 00-8 0v3h8v-3zM6 8a2 2 0 11-4 0 2 2 0 014 0zM16 18v-3a5.972 5.972 0 00-.75-2.906A3.005 3.005 0 0119 15v3h-3zM4.75 12.094A5.973 5.973 0 004 15v3H1v-3a3 3 0 013.75-2.906z" />'),
    # LobbyCard.ts lock
    "Lock": fill_svg('<path fill-rule="evenodd" d="M10 1a4.5 4.5 0 0 0-4.5 4.5V9H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-.5V5.5A4.5 4.5 0 0 0 10 1Zm3 8V5.5a3 3 0 1 0-6 0V9h6Z" clip-rule="evenodd" />'),
    # LanguageModal.ts active check
    "CheckCircle": fill_svg('<path fill-rule="evenodd" d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12zm13.36-1.814a.75.75 0 10-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 00-1.06 1.06l2.25 2.25a.75.75 0 001.14-.094l3.75-5.25z" clip-rule="evenodd" />', view="0 0 24 24"),
    # NewsBox.ts dismiss
    "X": fill_svg('<path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />'),
    # UsernameInput.ts clan check
    "Check": stroke_svg('<path d="M5 12.5l4.5 4.5L19 7" />', width="2.5"),
    # HelpModal.ts section icons
    "PlayTri": stroke_svg('<polygon points="5 3 19 12 5 21 5 3"></polygon>', width="2"),
    "Keyboard": stroke_svg('<rect x="2" y="4" width="20" height="16" rx="2" ry="2"></rect><path d="M6 8h.001"></path><path d="M10 8h.001"></path><path d="M14 8h.001"></path><path d="M18 8h.001"></path><path d="M6 12h.001"></path><path d="M10 12h.001"></path><path d="M14 12h.001"></path><path d="M18 12h.001"></path><path d="M6 16h12"></path>', width="2"),
    "Warning": stroke_svg('<path d="M2 20 L12 0 L22 20 L2 20"></path><line x1="12" y1="8" x2="12" y2="14"></line><line x1="12" y1="17" x2="12.01" y2="17"></line>', width="2"),
    "Layout": stroke_svg('<rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="3" y1="9" x2="21" y2="9"></line><line x1="9" y1="21" x2="9" y2="9"></line>', width="2"),
    "Radial": stroke_svg('<circle cx="12" cy="12" r="10"></circle><circle cx="12" cy="12" r="3"></circle>', width="2"),
    "Info": stroke_svg('<circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line>', width="2"),
    "Building": stroke_svg('<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"></path><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"></path><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"></path>', width="2"),
    "User": stroke_svg('<path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle>', width="2"),
}

FILES = {
    "Github": ("resources/icons/github-mark-white.svg", "A"),
    "LangFlag": ("resources/flags/uk_us_flag.svg", "RGBA"),
}


def render(svg_bytes, mode):
    png = cairosvg.svg2png(bytestring=svg_bytes, output_width=RENDER, output_height=RENDER)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    # Keep aspect: fit into the square, centred.
    bbox = im.getbbox()
    canvas = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
    canvas.paste(im, (0, 0))
    im = canvas.resize((SIZE, SIZE), Image.LANCZOS)
    if mode == "A":
        return bytes(im.split()[3].tobytes())
    return im.tobytes()


def render_flag(path):
    # Flags are 3:2 or 4:3 etc; render to the full square width and letterbox vertically.
    png = cairosvg.svg2png(url=path, output_width=RENDER)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    w, h = im.size
    scale = RENDER / max(w, h)
    im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
    canvas.paste(im, ((RENDER - im.size[0]) // 2, (RENDER - im.size[1]) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS).tobytes()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ofr", default="/home/claude/ofr")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "MenuIconsData.lua"))
    args = ap.parse_args()
    assert "proprietary" not in args.ofr

    entries = []
    for name, svg in INLINE.items():
        entries.append((name, "A", render(svg.encode(), "A")))
    for name, (rel, mode) in FILES.items():
        path = os.path.join(args.ofr, rel)
        if mode == "RGBA":
            data = render_flag(path)
        else:
            data = render(open(path, "rb").read(), mode)
        entries.append((name, mode, data))

    lines = [
        "--[[",
        "\tWar Front - main menu icons (OpenFront home-screen SVG icons as raw pixels for EditableImage).",
        "\tCopyright (C) 2026 Liam (lacedsc3ne). Licensed under the GNU AGPL v3 or later.",
        "\tBased on OpenFront: © OpenFront and Contributors - https://github.com/openfrontio/OpenFrontIO",
        "\tIcons from OpenFront's client source (AGPL-3.0) and resources/ (CC BY-SA 4.0), rasterized",
        "\tto 48x48 by gen_menu_icons.py. GENERATED FILE - edit gen_menu_icons.py and re-run it.",
        "]]",
        "",
        "-- StarterPlayer.StarterPlayerScripts.MenuIconsData (ModuleScript), read by MenuKit.icon.",
        "-- name -> { format (\"A\" | \"RGBA\"), base64 pixels }",
        "",
        "return {",
        f"\tSIZE = {SIZE},",
    ]
    for name, mode, data in entries:
        b64 = base64.b64encode(data).decode()
        lines.append(f'\t{name} = {{ "{mode}", "{b64}" }},')
    lines.append("}")
    lines.append("")
    src = "\n".join(lines)
    assert len(src) < 190_000, len(src)
    with open(args.out, "w") as f:
        f.write(src)
    print("wrote", args.out, len(src), "chars,", len(entries), "icons")


if __name__ == "__main__":
    main()
