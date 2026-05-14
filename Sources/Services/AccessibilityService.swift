import AppKit
import ApplicationServices

@Observable
final class AccessibilityService {
    static let shared = AccessibilityService()

    var isTrusted: Bool = AXIsProcessTrusted()

    private init() {
        poll()
    }

    private func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.isTrusted = AXIsProcessTrusted()
            self.poll()
        }
    }
}
