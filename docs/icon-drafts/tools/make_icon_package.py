"""Writes QuickEdit.icon (Icon Composer package) from draft A's layers, in Kelpi.icon's format.

Icon Composer fills the whole 1024 canvas with the body, so the body's 824 px are scaled
by 1024/824 around the center. The background fill and dark-mode colors live in icon.json.
"""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_icons as m

OUT = pathlib.Path(sys.argv[1]) / "QuickEdit.icon"
(OUT / "Assets").mkdir(parents=True, exist_ok=True)
S = 1024 / 824
G = f'<g transform="translate(512 512) scale({S:.5f}) translate(-512 -512)">'
rules, text, caret = m.a_layers()
caret = caret[1:]  # Icon Composer draws its own shadow; drop the blur glow
defs = ('<defs><linearGradient id="caret" gradientUnits="userSpaceOnUse" x1="0" y1="474" x2="0" y2="644">'
        '<stop offset="0" stop-color="#2f8bff"/><stop offset="1" stop-color="#0a64d8"/></linearGradient></defs>')
def svg(body, d=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'{d}{G}' + "".join(body) + "</g></svg>\n")
(OUT / "Assets" / "rules.svg").write_text(svg(rules))
(OUT / "Assets" / "text.svg").write_text(svg(text))
(OUT / "Assets" / "caret.svg").write_text(svg(caret, defs))

def grad(a, b):
    return {"linear-gradient": [a, b], "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}
def srgb(h):
    h = h.lstrip("#"); r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"
def group(name, dark=None, shadow="none", opacity=0.5):
    layer = {"image-name": f"{name}.svg", "name": name, "glass": False}
    if dark:
        layer["fill-specializations"] = [{"appearance": "dark", "value": {"solid": srgb(dark)}}]
    return {"layers": [layer], "shadow": {"kind": shadow, "opacity": opacity},
            "translucency": {"enabled": False, "value": 0.5}}

icon = {
    "fill-specializations": [
        {"value": grad(srgb("#ffffff"), srgb("#e9edf2"))},
        {"appearance": "dark", "value": grad(srgb("#2b313a"), srgb("#1b1f26"))},
    ],
    "groups": [  # first group is drawn on top, as in Kelpi.icon
        group("caret", shadow="neutral", opacity=0.4),
        group("text", dark="#77818f"),
        group("rules", dark="#3b4351"),
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
(OUT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
print("wrote", OUT)
