import AppKit
import ApplicationServices
import OSLog

// Private AX SPI: get the CoreGraphics window number behind an AXUIElement.
// Stable per-window identity (unlike count), so we can tell a RESPAWN (a brand
// new window) from a window that was already there.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

final class WindowObserverService {
    static let shared = WindowObserverService()
    private var timer: Timer?
    // Per-app: the set of window IDs we last saw (not just a count). Tracking
    // IDENTITY is what makes respawn-aware quitting possible.
    private var seenWindowIDs: [pid_t: Set<CGWindowID>] = [:]
    private let log = Logger(subsystem: "com.ryanfong.hypercharge", category: "WindowObserver")

    private init() {
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func start() {
        // Poll fast (0.4s). The old 2s interval lost the respawn race: an app
        // (e.g. Terminal) that auto-reopens a replacement window the instant its
        // last real window closes would, on the next 2s poll, look like it "still
        // has a window" → never quit. We now poll quickly AND track window
        // identity, so a respawn never masks the close.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true
        guard isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let excluded = UserDefaults.standard.stringArray(forKey: "exclusionList") ?? []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }

            let pid = app.processIdentifier
            let bundleId = app.bundleIdentifier ?? "\(pid)"
            guard !excluded.contains(bundleId) else { continue }

            // Count windows BOTH ways: by raw AX window objects (the always-works
            // truth) and by stable window ID (needed for respawn detection, but the
            // private SPI can fail). SAFETY: if the app HAS windows by count but we
            // got ZERO ids (SPI unavailable), DO NOT treat it as "no windows" — that
            // would terminate an app the user is using. Fall back to count-only.
            let windowCount = axWindows(for: app).count
            let currentIDs = axWindowIDs(for: app)
            let idsReliable = (currentIDs.count == windowCount) // every window yielded an id

            guard let prevIDs = seenWindowIDs[pid] else {
                // First time we've seen this app — record and don't touch it yet.
                if windowCount > 0 { seenWindowIDs[pid] = currentIDs }
                continue
            }

            if windowCount == 0 {
                // No windows at all → the classic "last window closed" case.
                if !prevIDs.isEmpty {
                    log.info("terminating \(app.localizedName ?? bundleId): had \(prevIDs.count) windows, now 0")
                    seenWindowIDs[pid] = []
                    app.terminate()
                }
                continue
            }

            // RESPAWN-AWARE QUIT (the fix): if EVERY window we previously saw is
            // now gone — yet the app still reports window(s) — those windows are
            // brand-new RESPAWNS (e.g. Terminal auto-reopening a fresh `-zsh` the
            // instant the user closed the real one). The user closed all the
            // windows they had; a respawn shouldn't keep the app alive. So quit
            // when the previously-seen set and the current set are DISJOINT.
            // GATED on idsReliable + a non-empty prior id set so a failed SPI can
            // NEVER cause a spurious terminate of an app that has real windows.
            if idsReliable && !prevIDs.isEmpty && prevIDs.intersection(currentIDs).isEmpty {
                log.info("terminating \(app.localizedName ?? bundleId): all \(prevIDs.count) prior windows closed; \(currentIDs.count) respawn(s) ignored")
                seenWindowIDs[pid] = []
                app.terminate()
                continue
            }

            // Normal case: some prior windows survive, or the SPI was unreliable
            // (degrade gracefully to count-based — never quit while windows exist).
            // Track the current id set as the new truth.
            seenWindowIDs[pid] = currentIDs
        }

        // Clean up entries for apps no longer running.
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        seenWindowIDs = seenWindowIDs.filter { runningPIDs.contains($0.key) }
    }

    /// The set of CoreGraphics window IDs for an app's AX windows. Empty if the
    /// app exposes no windows or AX is unavailable.
    private func axWindowIDs(for app: NSRunningApplication) -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for w in axWindows(for: app) {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid != 0 {
                ids.insert(wid)
            }
        }
        return ids
    }
}
