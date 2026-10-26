// Renders an SVG to a square PNG with a clear background through WebKit.
// NSImage drops the feDropShadow and Quick Look adds a white background, so the
// .icns and the page images come from here.
// Copied from Kelpi tools/icon. Usage: swift render_png.swift IN.svg OUT.png SIZE
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    FileHandle.standardError.write("usage: render_png.swift IN.svg OUT.png SIZE\n".data(using: .utf8)!)
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let size: Int
    init(size: Int) {
        self.size = size
        // Points equal pixels: the snapshot is taken at snapshotWidth below.
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.setValue(false, forKey: "drawsBackground")
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(size) / Double(NSScreen.main?.backingScaleFactor ?? 1))
        webView.takeSnapshot(with: config) { image, error in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard rep.pixelsWide == self.size, let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write("snapshot is \(rep.pixelsWide) px, want \(self.size)\n".data(using: .utf8)!)
                exit(1)
            }
            do { try png.write(to: outURL) } catch {
                FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(size: size)
let svg = try String(contentsOf: svgURL, encoding: .utf8)
let html = """
<html><body style="margin:0;background:transparent">
<img src="data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())" width="\(size)" height="\(size)" style="display:block">
</body></html>
"""
renderer.view.loadHTMLString(html, baseURL: nil)
app.run()
