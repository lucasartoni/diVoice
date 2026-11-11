import AppKit

let app = NSApplication.shared
// Screenshots for design reviews: renders and exits before the app starts.
ScreenRenderer.runIfRequested()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
