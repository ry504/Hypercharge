import AppKit
import ApplicationServices
import OSLog

final class WindowObserverService {
    static let shared = WindowObserverService()
    private var timer: Timer?
    private var seenWindows: [pid_t: Int] = [:]
    private let log = Logger(subsystem: "com.ryanfong.hypercharge", category: "WindowObserver")

    private init() {
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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

            let count = axWindows(for: app).count

            if count > 0 {
                // Record that this app has had windows
                seenWindows[pid] = count
            } else if let prev = seenWindows[pid], prev > 0 {
                // Had windows before, now has none — terminate
                log.info("terminating \(app.localizedName ?? bundleId): had \(prev) windows, now 0")
                seenWindows[pid] = 0
                app.terminate()
            }
            // If seenWindows[pid] is nil, app just launched — don't touch it yet
        }

        // Clean up entries for apps that are no longer running
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        seenWindows = seenWindows.filter { runningPIDs.contains($0.key) }
    }
}
