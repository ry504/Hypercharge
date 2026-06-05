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
    // Per-app: consecutive polls observed at ZERO windows. Used only for
    // aggressive-quit apps (below) to quit an app sitting window-less even when
    // Hypercharge never recorded a window for it first (e.g. a window that opened
    // + closed between polls, or a quit request that didn't take — the leftover
    // window-less Terminal case).
    private var zeroWindowPolls: [pid_t: Int] = [:]
    private let log = Logger(subsystem: "com.ryanfong.hypercharge", category: "WindowObserver")

    /// Bundle ids that should be quit WHENEVER they sit window-less — regardless of
    /// whether Hypercharge saw them open a window first. For everything else the
    /// safe rule applies (only quit on a real window→closed transition). Terminal is
    /// the canonical case: it can end up running with zero windows via paths
    /// Hypercharge never armed on. Stored in UserDefaults (`aggressiveQuitList`,
    /// seeded with Terminal) so it can be edited later without a code change.
    private var aggressiveQuitList: [String] {
        if let stored = UserDefaults.standard.stringArray(forKey: "aggressiveQuitList") {
            return stored
        }
        // Seed default on first run.
        let seed = ["com.apple.Terminal"]
        UserDefaults.standard.set(seed, forKey: "aggressiveQuitList")
        return seed
    }
    /// Consecutive 0-window polls before an aggressive-quit app is terminated.
    /// At 0.4s/poll, 3 ≈ 1.2s — long enough to not kill an app mid-launch or
    /// between closing one window and opening the next.
    private let aggressiveQuitGracePolls = 3

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

            let isAggressive = aggressiveQuitList.contains(bundleId)

            // Track the consecutive-zero-window streak (used only for aggressive
            // apps). Reset it the moment any window exists.
            if windowCount == 0 {
                zeroWindowPolls[pid, default: 0] += 1
            } else {
                zeroWindowPolls[pid] = 0
            }

            guard let prevIDs = seenWindowIDs[pid] else {
                // First time we've seen this app — record and don't touch it yet,
                // EXCEPT an aggressive app sitting window-less past the grace period
                // (the leftover window-less Terminal we never saw open a window).
                if windowCount > 0 {
                    seenWindowIDs[pid] = currentIDs
                } else if isAggressive && zeroWindowPolls[pid, default: 0] >= aggressiveQuitGracePolls {
                    log.info("terminating \(app.localizedName ?? bundleId): aggressive-quit, window-less for \(self.aggressiveQuitGracePolls) polls (never saw a window)")
                    zeroWindowPolls[pid] = 0
                    app.terminate()
                }
                continue
            }

            if windowCount == 0 {
                // No windows at all → the classic "last window closed" case.
                if !prevIDs.isEmpty {
                    log.info("terminating \(app.localizedName ?? bundleId): had \(prevIDs.count) windows, now 0")
                    seenWindowIDs[pid] = []
                    app.terminate()
                } else if isAggressive && zeroWindowPolls[pid, default: 0] >= aggressiveQuitGracePolls {
                    // Aggressive app that reached 0 windows via a path we didn't arm
                    // on (prior terminate didn't take, etc.) — quit it after grace.
                    log.info("terminating \(app.localizedName ?? bundleId): aggressive-quit, window-less for \(self.aggressiveQuitGracePolls) polls")
                    zeroWindowPolls[pid] = 0
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
        zeroWindowPolls = zeroWindowPolls.filter { runningPIDs.contains($0.key) }
    }

    /// The set of CoreGraphics window IDs for an app's AX windows. Empty if the
    /// app exposes no windows or AX is unavailable.
    ///
    /// Primary identity is the private AX SPI (`_AXUIElementGetWindow`). But that
    /// SPI returns 0/error for some windows — notably tmux-attached Terminal
    /// windows — which would shrink the id set below the AX window count, flip
    /// `idsReliable` false, and gate off respawn-aware quitting. So for any AX
    /// window the SPI couldn't resolve, we recover its CGWindowID by matching the
    /// AX window's frame (position+size) to a `CGWindowListCopyWindowInfo` entry
    /// for this pid and taking its `kCGWindowNumber`. AX window ids and
    /// CGWindowList numbers are the SAME namespace (both `CGWindowID` — the SPI
    /// literally returns the window number), so mixing them is safe.
    ///
    /// Matching by frame (rather than just topping up from any layer-0 CG window)
    /// is deliberate: Terminal exposes several persistent CG helper surfaces
    /// (full-width menubar-shadow strips at 0,0; an off-screen square cache
    /// window) that have NO AX-window counterpart. Those must never enter the id
    /// set — they're stable across polls, so a chrome id present in both the prior
    /// and current set would keep the prev∩current intersection non-empty and
    /// defeat respawn detection. A frame match only ever resolves a REAL window.
    private func axWindowIDs(for app: NSRunningApplication) -> Set<CGWindowID> {
        let windows = axWindows(for: app)
        guard !windows.isEmpty else { return [] }

        var ids = Set<CGWindowID>()
        var unresolved: [AXUIElement] = []
        for w in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid != 0 {
                ids.insert(wid)
            } else {
                unresolved.append(w)
            }
        }

        // SPI resolved every window — done.
        if unresolved.isEmpty { return ids }

        // Recover the unresolved windows' numbers by frame-matching against this
        // pid's CG windows. No AX/TCC needed for window numbers.
        let cgWindows = cgWindows(forOwnerPID: app.processIdentifier)
        for w in unresolved {
            guard let frame = axFrame(of: w),
                  let number = cgWindows.first(where: { framesMatch($0.bounds, frame) })?.number
            else { continue }
            ids.insert(number)
        }
        return ids
    }

    /// The AX window's screen frame (position + size), or nil if unavailable.
    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// `(number, bounds)` for every CG window owned by `pid`, across all Spaces.
    /// Window NUMBERS (`kCGWindowNumber`) are TCC-free — they need no Accessibility
    /// or Screen-Recording grant (only the window TITLE/IMAGE require Screen
    /// Recording, which we never read) — and are stable per-window for the
    /// window's lifetime, exactly like the AX SPI id. `.optionAll` includes
    /// windows on OTHER Spaces so the frame match works for a coder window the
    /// user has scrolled away from.
    private func cgWindows(forOwnerPID pid: pid_t) -> [(number: CGWindowID, bounds: CGRect)] {
        guard let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return (number, bounds)
        }
    }

    /// Two frames are the same window if their origin and size agree within 1pt
    /// (AX and CG occasionally disagree by a sub-pixel rounding step).
    private func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 1 && abs(a.origin.y - b.origin.y) <= 1 &&
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
