import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let observer = WindowObserverService.shared
    var model: HyperchargeModel?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    func showSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let model else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hypercharge Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }
}

func axWindows(for app: NSRunningApplication) -> [AXUIElement] {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else { return [] }
    return windows
}
