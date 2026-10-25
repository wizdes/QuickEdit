// A stand-in app for bench/tests/launchbench-test.sh. With --window it shows
// one titled window; without it, it runs with no window. It never writes a
// launch stamp. It quits on the normal quit Apple event.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var window: NSWindow?
if CommandLine.arguments.contains("--window") {
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Fake"
    w.makeKeyAndOrderFront(nil)
    window = w
}
app.activate()
app.run()
