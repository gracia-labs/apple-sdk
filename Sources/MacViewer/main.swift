#if os(macOS)

import AppKit

let options = ViewerOptions(arguments: CommandLine.arguments)

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
// Screenshot runs stay out of the Dock so they never steal focus.
app.setActivationPolicy(options.screenshotPath == nil ? .regular : .accessory)
app.run()

#endif  // os(macOS)
