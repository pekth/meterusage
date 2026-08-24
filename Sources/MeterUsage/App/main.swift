import AppKit

// Entry point.
//
// NSApplication is set up by hand rather than with SwiftUI's `@main App`:
//
// * `LSUIElement` in the bundle's Info.plist keeps the app out of the Dock and
//   out of the menu bar's app menu, but `swift run` has no bundle — setting the
//   activation policy in code makes both launch paths behave identically.
// * SwiftUI's `MenuBarExtra` scene would own the status item and hide the click
//   handling and popover behaviour the app needs (see `AppDelegate`).
//
// This file must stay `main.swift`: top-level code is only permitted there, and
// it is what gives SwiftPM an executable entry point.

// Headless scriptable mode: `meterusage json [--force]` prints the limits
// report as JSON and exits before AppKit is ever touched, so it can run from
// agents, cron, or scripts without launching the menu-bar app.
if CliMode.wantsJSON(CommandLine.arguments) {
    let report = await CliMode.run()
    if let data = try? report.jsonData() {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        FileHandle.standardError.write(Data("meterusage: could not encode report\n".utf8))
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared

// `.accessory`: no Dock tile, no app menu, but still able to show windows and
// become key — which `.prohibited` would prevent, breaking the popover.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
