import AppKit

LaunchStamp.markMain()
Signposts.mark(.mainStart)

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
Defaults.register()
// The first NSDocumentController made becomes the shared one.
_ = DocumentController()
app.mainMenu = MainMenu.build()
Signposts.mark(.menuBuilt)
app.run()
