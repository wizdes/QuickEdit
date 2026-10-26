"""Writes three QuickEdit icon drafts as 1024 px SVGs.

Canvas 1024. Body: an 824 px continuous-corner square (superellipse, n = 5), centered,
the same grid as Kelpi. Each draft is built from layers so the best one can also be
written as Icon Composer layers (see make_icon_package.py).

A: white sheet, ruled lines, gray text bars, a bold blue caret.
B: bold "Aa" in SF Mono on a lined page, tilted.
C: a white page with a folded corner on a blue body; the cursor is a lightning bolt.
"""
import json
import math
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent
C, HALF, N = 512.0, 412.0, 5.0


def squircle(cx, cy, half, n=N, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + half * math.copysign(abs(c) ** (2 / n), c):.2f},"
                   f"{cy + half * math.copysign(abs(s) ** (2 / n), s):.2f}")
    return "M" + " L".join(pts) + " Z"


BODY = squircle(C, C, HALF)
RIM = squircle(C, C, HALF - 0.75)


def bar(x1, x2, y, h, fill):
    """A round-ended horizontal bar centered on y."""
    return f'<rect x="{x1}" y="{y - h / 2}" width="{x2 - x1}" height="{h}" rx="{h / 2}" fill="{fill}"/>'


def wrap(paper_fill, layers, extra_defs="", shadow_color="#0b1a30"):
    """Puts layers on the rounded body with a drop shadow, a top gloss and a thin rim."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="{shadow_color}" flood-opacity="0.30"/>
  </filter>
  <clipPath id="body"><path d="{BODY}"/></clipPath>
  <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="0.30"/>
    <stop offset="0.45" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  {extra_defs}
</defs>
<path d="{BODY}" fill="{paper_fill}" filter="url(#shadow)"/>
<g clip-path="url(#body)">
{chr(10).join(layers)}
  <rect x="100" y="100" width="824" height="824" fill="url(#gloss)"/>
</g>
<path d="{RIM}" fill="none" stroke="{shadow_color}" stroke-opacity="0.20" stroke-width="1.5"/>
</svg>
"""


# ---------- A: caret on a clean sheet ----------
A_RULE_Y = [352, 472, 592, 712, 832]
A_TEXT = [(206, 770), (206, 640), (206, 430)]  # text bars sit on the first three rules
A_CARET = dict(x=470, w=64, top=474, bottom=644)  # after the third bar, clear of the second


def a_layers():
    rules = [f'<rect x="100" y="{y - 4}" width="824" height="8" fill="#d6dde6"/>' for y in A_RULE_Y]
    text = [bar(x1, x2, A_RULE_Y[i] - 40, 40, "#a3acb8") for i, (x1, x2) in enumerate(A_TEXT)]
    k = A_CARET
    caret = [
        f'<rect x="{k["x"] - 18}" y="{k["top"] - 18}" width="{k["w"] + 36}" height="{k["bottom"] - k["top"] + 36}" '
        f'rx="40" fill="#1a7cf5" opacity="0.22" filter="url(#glow)"/>',
        f'<rect x="{k["x"]}" y="{k["top"]}" width="{k["w"]}" height="{k["bottom"] - k["top"]}" rx="14" fill="url(#caret)"/>',
    ]
    return rules, text, caret


A_DEFS = """<linearGradient id="paperA" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e9edf2"/></linearGradient>
  <linearGradient id="caret" gradientUnits="userSpaceOnUse" x1="0" y1="474" x2="0" y2="644">
    <stop offset="0" stop-color="#2f8bff"/><stop offset="1" stop-color="#0a64d8"/></linearGradient>
  <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="16"/></filter>"""


def draft_a():
    rules, text, caret = a_layers()
    return wrap("url(#paperA)", rules + text + caret, A_DEFS)


# ---------- B: "Aa" in SF Mono on a lined page ----------
B_RULE_Y = [224 + 96 * k for k in range(8)]
B_BASELINE = 704
B_TILT = -6


def b_glyphs():
    d = json.loads((HERE / "aa.json").read_text())
    scale = 1.32  # 400 pt outline -> about 600 px wide
    w = d["w"] * scale
    tx = C - (d["x"] * scale + w / 2)
    return d["d"], scale, tx


def b_layers():
    rules = [f'<rect x="100" y="{y - 5}" width="824" height="10" fill="#bcd0e6"/>' for y in B_RULE_Y]
    margin = ['<rect x="214" y="100" width="8" height="824" fill="#eaa3a3"/>']
    d, scale, tx = b_glyphs()
    ink = [f'<g transform="rotate({B_TILT} {C} {B_BASELINE - 180})">'
           f'<path d="{d}" transform="translate({tx:.2f} {B_BASELINE}) scale({scale})" fill="url(#inkB)"/></g>']
    return rules, margin, ink


B_DEFS = """<linearGradient id="paperB" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fdfcf8"/><stop offset="1" stop-color="#ece8dd"/></linearGradient>
  <linearGradient id="inkB" gradientUnits="userSpaceOnUse" x1="0" y1="330" x2="0" y2="720">
    <stop offset="0" stop-color="#2d3440"/><stop offset="1" stop-color="#161a21"/></linearGradient>"""


def draft_b():
    rules, margin, ink = b_layers()
    return wrap("url(#paperB)", rules + margin + ink, B_DEFS, shadow_color="#2a2416")


# ---------- C: page with a lightning-bolt cursor on a blue body ----------
# Page: 560 x 680, centered, top-right corner folded.
PX1, PY1, PX2, PY2, FOLD, PR = 232, 180, 792, 860, 150, 34
C_TEXT_Y = [372, 462, 552]
C_TEXT = [(300, 690), (300, 610), (300, 470)]
# Bolt: tall and narrow so it reads as a text cursor; sits after the third text bar.
BOLT = [(x, y + 64) for x, y in [(574, 456), (512, 600), (552, 600), (520, 724), (618, 560), (574, 560), (606, 456)]]  # below the second bar


def page_path():
    return (f"M{PX1 + PR},{PY1} L{PX2 - FOLD},{PY1} L{PX2},{PY1 + FOLD} L{PX2},{PY2 - PR} "
            f"Q{PX2},{PY2} {PX2 - PR},{PY2} L{PX1 + PR},{PY2} Q{PX1},{PY2} {PX1},{PY2 - PR} "
            f"L{PX1},{PY1 + PR} Q{PX1},{PY1} {PX1 + PR},{PY1} Z")


def fold_path():
    return f"M{PX2 - FOLD},{PY1} L{PX2 - FOLD},{PY1 + FOLD - 26} Q{PX2 - FOLD},{PY1 + FOLD} {PX2 - FOLD + 26},{PY1 + FOLD} L{PX2},{PY1 + FOLD} Z"


def bolt_path():
    return "M" + " L".join(f"{x},{y}" for x, y in BOLT) + " Z"


def c_layers():
    page = [f'<path d="{page_path()}" fill="url(#paperC)" filter="url(#pageShadow)"/>',
            f'<path d="{fold_path()}" fill="#cfd9ea"/>']
    text = [bar(x1, x2, C_TEXT_Y[i], 40, "#aeb7c4") for i, (x1, x2) in enumerate(C_TEXT)]
    bolt = [f'<path d="{bolt_path()}" fill="#1f5fe0" stroke="#1f5fe0" stroke-width="14" stroke-linejoin="round"/>']
    return page, text, bolt


C_DEFS = """<linearGradient id="bodyC" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#4a8cff"/><stop offset="1" stop-color="#1f5fe0"/></linearGradient>
  <linearGradient id="paperC" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#eef2f8"/></linearGradient>
  <filter id="pageShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#0a2a6b" flood-opacity="0.35"/></filter>"""


def draft_c():
    page, text, bolt = c_layers()
    return wrap("url(#bodyC)", page + text + bolt, C_DEFS, shadow_color="#0a2a6b")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in [("draft-a-caret", draft_a), ("draft-b-aa", draft_b), ("draft-c-bolt", draft_c)]:
        (OUT / f"{name}.svg").write_text(fn())
        print("wrote", OUT / f"{name}.svg")
