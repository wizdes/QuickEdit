"""Writes sheet.svg: each draft at 1024, 128 and 32 px (actual pixels), on light and dark rows."""
import base64, pathlib, sys
O = pathlib.Path(sys.argv[1])
names = [("draft-a-caret", "A  caret"), ("draft-b-aa", "B  Aa"), ("draft-c-bolt", "C  bolt")]
W, ROW = 3720, 1140
def img(path, x, y, s):
    b = base64.b64encode(path.read_bytes()).decode()
    return f'<image x="{x}" y="{y}" width="{s}" height="{s}" href="data:image/png;base64,{b}" style="image-rendering:pixelated"/>'
parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{2*ROW}" viewBox="0 0 {W} {2*ROW}">']
for r, (bg, fg) in enumerate([("#f2f2f5", "#333"), ("#1c1c1f", "#ddd")]):
    y0 = r * ROW
    parts.append(f'<rect x="0" y="{y0}" width="{W}" height="{ROW}" fill="{bg}"/>')
    for i, (n, label) in enumerate(names):
        x0 = 40 + i * 1230
        parts.append(f'<text x="{x0 + 20}" y="{y0 + 70}" font-family="-apple-system, Helvetica" font-size="44" fill="{fg}">{label}</text>')
        parts.append(img(O / "png" / f"{n}-1024.png", x0, y0 + 100, 1024))
        parts.append(img(O / "png" / f"{n}-128.png", x0 + 1044, y0 + 100, 128))
        parts.append(img(O / "png" / f"{n}-32.png", x0 + 1044, y0 + 260, 32))
        parts.append(img(O / "png" / f"{n}-32.png", x0 + 1044, y0 + 320, 128))
        parts.append(f'<text x="{x0 + 1044}" y="{y0 + 470}" font-family="-apple-system, Helvetica" font-size="20" fill="{fg}">32 px, then 4x</text>')
parts.append("</svg>")
(O / "sheet.svg").write_text("\n".join(parts))
