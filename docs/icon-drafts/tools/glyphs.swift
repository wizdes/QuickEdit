// Prints SVG path data for a string in SF Mono Bold, with the baseline at y=0,
// x starting at 0, y pointing down, at the given point size. Also prints the advance width.
// Usage: swift glyphs.swift TEXT SIZE
import AppKit
import CoreText
let a = CommandLine.arguments
let text = a[1]; let size = CGFloat(Double(a[2])!)
let font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold) as CTFont
let attr = NSAttributedString(string: text, attributes: [.font: font])
let line = CTLineCreateWithAttributedString(attr)
var out = ""
func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let n = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: n); var pos = [CGPoint](repeating: .zero, count: n)
    CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
    for i in 0..<n {
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pos[i].x, ty: 0)
        guard let p = CTFontCreatePathForGlyph(font, glyphs[i], &t) else { continue }
        p.applyWithBlock { e in
            let el = e.pointee; let pts = el.points
            switch el.type {
            case .moveToPoint: out += "M\(f(pts[0].x)),\(f(pts[0].y)) "
            case .addLineToPoint: out += "L\(f(pts[0].x)),\(f(pts[0].y)) "
            case .addQuadCurveToPoint: out += "Q\(f(pts[0].x)),\(f(pts[0].y)) \(f(pts[1].x)),\(f(pts[1].y)) "
            case .addCurveToPoint: out += "C\(f(pts[0].x)),\(f(pts[0].y)) \(f(pts[1].x)),\(f(pts[1].y)) \(f(pts[2].x)),\(f(pts[2].y)) "
            case .closeSubpath: out += "Z "
            @unknown default: break
            }
        }
    }
}
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
print("{\"font\": \"\(CTFontCopyFullName(font))\", \"d\": \"\(out.trimmingCharacters(in: .whitespaces))\", \"x\": \(f(bounds.minX)), \"w\": \(f(bounds.width)), \"top\": \(f(-bounds.maxY)), \"bottom\": \(f(-bounds.minY))}")
