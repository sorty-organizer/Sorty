#!/usr/bin/env python3
"""Render white activity mascots from SVG shapes. Requires librsvg."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/SortyLib/Resources/Images"

# Transparent face panels and broad strokes stay legible at menu bar size.
HEAD = '''
<path d="M32 21V13" stroke="white" stroke-width="4"/>
<circle cx="32" cy="9" r="5" fill="white"/>
<rect x="10" y="21" width="44" height="35" rx="13"
      stroke="white" stroke-width="4" fill="none"/>
<rect x="4" y="31" width="5" height="16" rx="2.5" fill="white"/>
<rect x="55" y="31" width="5" height="16" rx="2.5" fill="white"/>
<path d="M20 37Q24 29 28 37M36 37Q40 29 44 37M27 44Q32 49 37 44"
      stroke="white" stroke-width="3" stroke-linecap="round" fill="none"/>
'''

PROPS = {
    "Idle": "",
    "Greeting": '''<path d="M10 41L5 31M5 31V22M5 27L2 24M5 26L9 22"
        fill="none" stroke="white" stroke-width="3" stroke-linecap="round"/>
        <path d="M1 17Q5 13 10 16" fill="none" stroke="white" stroke-width="2"
        stroke-linecap="round"/>''',
    "Organizing": '''<path d="M9 42H26L31 47H55V60H9Z" fill="white"/>
        <path d="M32 47V55M28 52L32 56L36 52" fill="none" stroke="black"
        stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>''',
    "Renaming": '''<path d="M8 54L46 41L51 52L13 65L5 62Z" fill="white"/>
        <path d="M43 43L47 54M9 56L13 64" stroke="black" stroke-width="2"/>''',
    "WatchedFolder": '''<path d="M5 51Q32 29 59 51Q32 73 5 51Z" fill="white"/>
        <circle cx="32" cy="51" r="8" fill="black"/>
        <circle cx="30" cy="49" r="2.5" fill="white"/>''',
    "DuplicateScanning": '''<path d="M7 39H23L27 43H42V57H7Z" fill="white"/>
        <path d="M24 46H40L44 50H59V64H24Z" fill="white" stroke="black"
        stroke-width="2.5"/>
        <circle cx="41" cy="57" r="3" fill="black"/>''',
    "Learning": '''<rect x="8" y="43" width="22" height="9" rx="4" fill="white"/>
        <rect x="34" y="43" width="22" height="9" rx="4" fill="white"/>
        <rect x="8" y="55" width="22" height="9" rx="4" fill="white"/>
        <rect x="34" y="55" width="22" height="9" rx="4" fill="white"/>''',
}


def main():
    for activity, prop in PROPS.items():
        # Black marks in the prop mask become transparent, never painted black.
        svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"
            viewBox="0 0 68 68">
            <defs><mask id="prop"><rect width="68" height="68" fill="black"/>
            {prop}</mask>
            <mask id="head"><rect width="68" height="68" fill="white"/>
            {prop.replace('white', 'black')}</mask></defs>
            <g transform="translate(2 0)"><g mask="url(#head)">{HEAD}</g>
            <rect width="68" height="68" fill="white" mask="url(#prop)"/>
            </g></svg>'''
        source = OUTPUT / f"SortyMenuWhite{activity}.svg"
        source.write_text(svg + "\n")
        subprocess.run([
            "rsvg-convert", str(source), "-o", str(source.with_suffix(".png")),
        ], check=True)


if __name__ == "__main__":
    main()
