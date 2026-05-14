import Foundation

@Observable
final class HyperchargeModel {
    var isEnabled: Bool {
        didSet { save() }
    }

    var exclusionList: [String] {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.exclusionList = defaults.stringArray(forKey: "exclusionList") ?? []
    }

    func isExcluded(_ bundleIdentifier: String) -> Bool {
        exclusionList.contains(bundleIdentifier)
    }

    func toggleExclusion(_ bundleIdentifier: String) {
        if isExcluded(bundleIdentifier) {
            exclusionList.removeAll { $0 == bundleIdentifier }
        } else {
            exclusionList.append(bundleIdentifier)
        }
    }

    private func save() {
        defaults.set(isEnabled, forKey: "isEnabled")
        defaults.set(exclusionList, forKey: "exclusionList")
    }
}
