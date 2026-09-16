"""Draws the extension's debug-toolbar icons into vscode-extension/media/toolbar.

One SVG per button per theme: a file icon does not follow the theme's
foreground the way a codicon does, so each needs a light variant (deeper, for
contrast on white) and a dark one (brighter). 16x16 with the drawing inside
14x14, and strokes of 2 so they carry the same weight as VS Code's own
Continue and Step buttons rather than looking like hairlines beside them.
"""

import os
import xml.etree.ElementTree as ET

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "vscode-extension", "media", "toolbar")

# dark variant first (brighter, for a dark toolbar), then light (deeper).
COLOURS = {
    "speed": ("#4FA3E3", "#1F6FB5"),           # blue: a dial you turn
    "profile-start": ("#F2C14E", "#C08A00"),   # yellow: recording
    "profile-stop": ("#E05B52", "#C0392B"),    # red: stop recording
    "step-back-into": ("#A788E8", "#6A3FBF"),  # violet: backwards
    "step-back-out": ("#8A63D2", "#5433A8"),   # ...deeper, one step further out
    "return-to-live": ("#5BC46E", "#2E8B45"),  # green: back to now
}

# {c} is the colour. Geometry is worked out rather than eyeballed: the gauge's
# arc is a true semicircle, the flame's bowl is a circle its sides are tangent
# to, and every arrowhead is a triangle whose tip is the point being made.
SHAPES = {
    # A speedometer: semicircular dial, needle at half past ten.
    "speed": (
        '<path d="M2.5 12 A5.5 5.5 0 0 1 13.5 12" fill="none" stroke="{c}" '
        'stroke-width="2" stroke-linecap="round"/>'
        '<path d="M8 12 L11.4 7.6" fill="none" stroke="{c}" stroke-width="2" '
        'stroke-linecap="round"/>'
        '<circle cx="8" cy="12" r="1.5" fill="{c}"/>'
    ),
    # A flame: a round base, a leaning tip, and the notch up its left side
    # that stops it reading as a drop of water.
    "profile-start": (
        '<path d="M8.6 1.4 C9.9 4.5 12 5.7 12 8.7 A4 4 0 0 1 4 8.7 '
        'C4 7.1 4.8 5.9 5.9 4.9 C5.7 6.4 6.1 7.3 6.9 7.7 '
        'C7.8 8.1 7.8 6.4 7.2 4.7 C6.8 3.5 7.4 2.3 8.6 1.4 Z" fill="{c}"/>'
    ),
    # The usual stop square.
    "profile-stop": '<rect x="3.5" y="3.5" width="9" height="9" rx="1.6" fill="{c}"/>',
    # Back one instruction, whatever it was: an arrow pointing the way
    # execution came from, into a dot -- the mirror of VS Code's own Step
    # Into, which is an arrow into a dot pointing the other way.
    "step-back-into": (
        '<path d="M13.4 8 H8.4" fill="none" stroke="{c}" stroke-width="2" '
        'stroke-linecap="round"/>'
        '<path d="M4.2 8 L9 4.6 V11.4 Z" fill="{c}"/>'
        '<circle cx="2.3" cy="8" r="1.8" fill="{c}"/>'
    ),
    # Back out of a routine: the same arrow, turning up and out of it.
    "step-back-out": (
        '<path d="M12.8 12.4 H6 V7.2" fill="none" stroke="{c}" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        '<path d="M6 2.4 L9.4 7.6 H2.6 Z" fill="{c}"/>'
    ),
    # Return to live: forwards, to the bar at the end.
    "return-to-live": (
        '<path d="M2.4 8 H8.2" fill="none" stroke="{c}" stroke-width="2" '
        'stroke-linecap="round"/>'
        '<path d="M12.6 8 L7.6 4.6 V11.4 Z" fill="{c}"/>'
        '<path d="M14 3.8 V12.2" fill="none" stroke="{c}" stroke-width="2" '
        'stroke-linecap="round"/>'
    ),
}

os.makedirs(OUT, exist_ok=True)
written = []
for name, body in SHAPES.items():
    for theme, colour in zip(("dark", "light"), COLOURS[name]):
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" '
            'viewBox="0 0 16 16">' + body.format(c=colour) + "</svg>\n"
        )
        ET.fromstring(svg)  # it has to parse, or VS Code shows nothing at all
        path = os.path.join(OUT, f"{name}-{theme}.svg")
        with open(path, "w", encoding="utf8", newline="\n") as f:
            f.write(svg)
        written.append(os.path.basename(path))
print(len(written), "icons:", ", ".join(written))
