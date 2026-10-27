// Copied from Kelpi (bench/frames.swift, commit 571ac9f) for QuickEdit 1.2.0 change 5.
// frames MOVIE OUT_DIR FPS: reads a screen recording and writes every frame that differs from
// the last written one by more than 0.05% of its pixels (a channel change of more than 24 of
// 255). The cursor blink is below that; a tab bar, a text line or a blank editor is above it.
// Prints one line per written frame with the fraction of pixels that changed, then a summary.
import AVFoundation
import AppKit
let args = CommandLine.arguments
guard args.count >= 4, let fps = Double(args[3]) else { print("usage: frames MOVIE OUT_DIR FPS"); exit(2) }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = args[2]
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let duration = CMTimeGetSeconds(asset.duration)
let limit = 0.0005
var last: [UInt8]? = nil
var t = 0.0, i = 0, written = 0
func pixels(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return data
}
while t < duration {
    let time = CMTime(seconds: t, preferredTimescale: 600)
    if let cg = try? gen.copyCGImage(at: time, actualTime: nil), let px = pixels(cg) {
        var changed = 0.0
        if let last, last.count == px.count {
            var n = 0
            var p = 0
            while p < px.count {
                if abs(Int(px[p]) - Int(last[p])) > 24 || abs(Int(px[p + 1]) - Int(last[p + 1])) > 24 || abs(Int(px[p + 2]) - Int(last[p + 2])) > 24 { n += 1 }
                p += 4
            }
            changed = Double(n) / Double(px.count / 4)
        } else {
            changed = 1
        }
        if changed > limit {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                let name = String(format: "f%04d_%.3f.png", i, t)
                try? png.write(to: URL(fileURLWithPath: out + "/" + name))
                print(String(format: "frame %@ changed %.4f", name, changed))
                written += 1
            }
            last = px
        }
    }
    t += 1.0 / fps
    i += 1
}
print("duration \(duration) frames \(i) written \(written)")
