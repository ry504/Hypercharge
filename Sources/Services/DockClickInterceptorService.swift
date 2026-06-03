import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

/// Implements "click Dock icon to hide/show app".
///
/// Detection uses a passive (listen-only) CGEventTap on `leftMouseDown` AND `leftMouseUp`.
/// macOS gives no direct "a Dock icon was clicked" API, and the Dock is a background agent
/// that never "activates", so AX activation notifications are useless here.
///
/// The key timing detail: the Dock performs its own activation/unhide on mouse-UP (release),
/// not mouse-down. If we act on mouse-down we race the Dock and lose on a normal click. So:
///  - On mouse-DOWN we hit-test the Accessibility element under the cursor; if it's an
///    AXApplicationDockItem owned by the Dock process we resolve the app it represents (via
///    its file URL → bundle identifier, falling back to title match) and STORE the pending
///    intent: the target app, its `isHidden` state, the frontmost app, and the down location.
///    We perform NO hide/unhide on down.
///  - On mouse-UP we apply the toggle (on the next main-queue tick, so it runs AFTER the
///    Dock processed the click) based on the state captured at down. Because the Dock
///    auto-unhides a hidden app, the ONLY action we ever take is HIDING an already-frontmost
///    app; the show/raise cases are handled for us by the Dock. This eliminates the race.
/// The tap is listen-only: events are returned unmodified and never consumed.
final class DockClickInterceptorService {
    static let shared = DockClickInterceptorService()
    private let log = Logger(subsystem: "com.ryanfong.hypercharge", category: "DockClickInterceptor")

    private static let dockBundleId = "com.apple.dock"
    private static let suppressWindow: TimeInterval = 0.3
    /// Max pointer drift (points) between mouse-down and mouse-up to still count as a click.
    private static let clickDriftTolerance: CGFloat = 10

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Pending dock-click intent captured at mouse-down, applied at mouse-up.
    private struct PendingClick {
        let app: NSRunningApplication
        let wasHiddenAtDown: Bool
        let frontmostAtDown: NSRunningApplication?
        let downLocation: CGPoint
    }
    private var pending: PendingClick?

    /// Bundle ids we are actively toggling, so our own hide/unhide/activate calls
    /// don't re-feed through detection and re-toggle. (Low risk with an event tap,
    /// but kept as a harmless guard.)
    private var suppressedBundleIds = Set<String>()

    private init() {
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func start() {
        installEventTap()
    }

    // MARK: - Event tap

    private func installEventTap() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        )
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<DockClickInterceptorService>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .leftMouseDown:
                service.handleLeftMouseDown(at: event.location)
            case .leftMouseUp:
                service.handleLeftMouseUp(at: event.location)
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // A listen-only tap can be disabled by the system under load. Re-enable it.
                service.log.notice("Event tap disabled (type=\(type.rawValue)); re-enabling")
                if let tap = service.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                _ = proxy
            default:
                break
            }
            // Listen-only: always return the event unmodified.
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            log.error("Failed to create CGEventTap for Dock click detection (not permitted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        log.notice("Dock click event tap installed")
    }

    // MARK: - Detection

    /// Called from the event tap on every left mouse-down.
    /// Decides intent only: hit-tests the dock item, resolves the app, and records the
    /// pending click state. Performs NO hide/unhide here — that happens on mouse-up.
    /// - Parameter location: global mouse location in top-left-origin coords (CGEvent location),
    ///   which is the same coordinate space `AXUIElementCopyElementAtPosition` expects.
    private func handleLeftMouseDown(at location: CGPoint) {
        // Unconditional diagnostic: prove the tap callback fires for every mouse-down.
        log.debug("mouseDown at (\(location.x, privacy: .public), \(location.y, privacy: .public))")

        // Always clear stale pending state; only re-arm if this is a valid dock click.
        pending = nil

        guard isFeatureEnabled else {
            log.debug("mouseDown: feature disabled, ignoring")
            return
        }
        guard AXIsProcessTrusted() else {
            log.debug("mouseDown: AX not trusted, ignoring")
            return
        }

        guard let target = resolveDockTarget(at: location) else {
            // resolveDockTarget logs the specific reason it failed.
            return
        }

        // Capture state SYNCHRONOUSLY at down, before the OS brings the clicked app forward.
        let wasHidden = target.isHidden
        let frontmost = NSWorkspace.shared.frontmostApplication

        let name = target.localizedName ?? target.bundleIdentifier ?? "\(target.processIdentifier)"
        let isFrontmost = (target == frontmost)
        log.debug("Dock item clicked at down: \(name, privacy: .public), hidden=\(wasHidden), frontmost=\(isFrontmost)")

        pending = PendingClick(
            app: target,
            wasHiddenAtDown: wasHidden,
            frontmostAtDown: frontmost,
            downLocation: location
        )
    }

    /// Called from the event tap on every left mouse-up.
    /// Applies the toggle (on the next main-queue tick, AFTER the Dock has acted) based on
    /// the state captured at mouse-down. Because the Dock auto-unhides/raises apps on click,
    /// the only action we ever take is HIDING an already-frontmost app.
    private func handleLeftMouseUp(at location: CGPoint) {
        guard let click = pending else {
            log.debug("mouseUp: no pending dock click")
            return
        }
        pending = nil
        log.debug("mouseUp: pending click exists, applying toggle")

        // A drag (significant pointer drift) is not a click — ignore it.
        let dx = location.x - click.downLocation.x
        let dy = location.y - click.downLocation.y
        if (dx * dx + dy * dy) > (Self.clickDriftTolerance * Self.clickDriftTolerance) {
            log.debug("mouseUp: drift exceeded tolerance, treating as drag")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyToggle(click)
        }
    }

    /// Resolves the AX element under the cursor to a running app, but ONLY if that element
    /// is a Dock item owned by the Dock process. Returns nil otherwise (or if the app the
    /// dock item represents isn't currently running — let the Dock launch it normally).
    private func resolveDockTarget(at location: CGPoint) -> NSRunningApplication? {
        // CGEvent.location is already global, top-left-origin screen coords — exactly what
        // AXUIElementCopyElementAtPosition expects. Pass straight through as Float, NO flip.
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let copyResult = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        )

        let dockPid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.dockBundleId
        })?.processIdentifier ?? -1

        guard copyResult == .success, let hit = element else {
            log.debug("hitTest: no element (result=\(copyResult.rawValue, privacy: .public)) dockPid=\(dockPid, privacy: .public)")
            return nil
        }

        var hitPid: pid_t = 0
        AXUIElementGetPid(hit, &hitPid)
        let hitRole = copyStringAttribute(hit, kAXRoleAttribute as CFString)
        let hitSubrole = copyStringAttribute(hit, kAXSubroleAttribute as CFString)
        log.debug("hitTest: role=\(hitRole ?? "nil", privacy: .public) subrole=\(hitSubrole ?? "nil", privacy: .public) pid=\(hitPid, privacy: .public) dockPid=\(dockPid, privacy: .public)")

        // The element under the cursor may be the dock item itself OR a child (e.g. the image).
        // Walk up via the parent chain (max 4 levels) looking for a DockItem role/subrole.
        guard let dockItem = findDockItem(from: hit) else {
            log.debug("hitTest: not a dock item (no DockItem in role/subrole chain)")
            return nil
        }

        // Must belong to the Dock process.
        var elementPid: pid_t = 0
        guard AXUIElementGetPid(dockItem, &elementPid) == .success else {
            log.debug("hitTest: could not read dock item pid")
            return nil
        }
        guard dockPid != -1, elementPid == dockPid else {
            log.debug("hitTest: dock item pid=\(elementPid, privacy: .public) != dockPid=\(dockPid, privacy: .public)")
            return nil
        }

        // Prefer the bundle URL (most reliable), fall back to the title.
        let bundleURL = copyURLAttribute(dockItem, kAXURLAttribute as CFString)
        let title = copyStringAttribute(dockItem, kAXTitleAttribute as CFString)

        if let bundleURL,
           let bundleId = Bundle(url: bundleURL)?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            log.debug("resolved app via bundle URL: \(bundleId, privacy: .public)")
            return app
        }

        if let title,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName == title
           }) {
            log.debug("resolved app via title: \(title, privacy: .public)")
            return app
        }

        log.debug("hitTest: dock item found but app not resolved (url=\(bundleURL?.path ?? "nil", privacy: .public) title=\(title ?? "nil", privacy: .public)) — likely not running")
        return nil
    }

    /// Walks up the AX parent chain (including the starting element) looking for an element
    /// whose role OR subrole indicates a Dock item. Modern macOS reports role "AXDockItem"
    /// with subrole "AXApplicationDockItem"; older code only checked the role, which is the bug.
    private func findDockItem(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let el = current, depth < 5 {
            if isDockItem(el) {
                return el
            }
            current = copyElementAttribute(el, kAXParentAttribute as CFString)
            depth += 1
        }
        return nil
    }

    /// True if the element's role OR subrole contains "DockItem".
    private func isDockItem(_ element: AXUIElement) -> Bool {
        if let role = copyStringAttribute(element, kAXRoleAttribute as CFString),
           role.contains("DockItem") {
            return true
        }
        if let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString),
           subrole.contains("DockItem") {
            return true
        }
        return false
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func copyURLAttribute(_ element: AXUIElement, _ attribute: CFString) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? URL
    }

    // MARK: - Toggle logic

    /// Applies the toggle based on the state captured at mouse-down, running AFTER the Dock
    /// has already processed the click. Toggle semantics:
    ///  - hidden at down → Dock already unhid+activated it → do nothing (toggle to visible) ✓
    ///  - frontmost at down (visible) → Dock does nothing useful → we hide it (toggle to hidden) ✓
    ///  - background at down (visible, not frontmost) → Dock raised it → do nothing ✓
    /// The only action we ever take is hiding an already-frontmost app.
    private func applyToggle(_ click: PendingClick) {
        let app = click.app

        guard isFeatureEnabled else { return }
        guard AXIsProcessTrusted() else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard app.activationPolicy == .regular else { return }
        // Guard against re-entrancy from our own hide/unhide/activate calls.
        if let bundleId = app.bundleIdentifier, suppressedBundleIds.contains(bundleId) { return }
        // NOTE: the Dock toggle deliberately ignores the exclusion list — it applies to all apps.

        let name = app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)"

        if click.wasHiddenAtDown {
            // Dock already unhid+activated it → leave it shown.
        } else if app == click.frontmostAtDown {
            // It was visible and frontmost when clicked → hide it.
            log.notice("Hide \(name, privacy: .public)")
            suppress(app) {
                app.hide()
            }
        } else {
            // Running but not frontmost → Dock brought it forward; let that stand.
        }
    }

    /// Runs `action` while suppressing re-entrant toggle handling for `app`.
    private func suppress(_ app: NSRunningApplication, _ action: () -> Void) {
        guard let bundleId = app.bundleIdentifier else {
            action()
            return
        }
        suppressedBundleIds.insert(bundleId)
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suppressWindow) { [weak self] in
            self?.suppressedBundleIds.remove(bundleId)
        }
    }

    private var isFeatureEnabled: Bool {
        UserDefaults.standard.object(forKey: "dockToggleEnabled") as? Bool ?? false
    }
}
