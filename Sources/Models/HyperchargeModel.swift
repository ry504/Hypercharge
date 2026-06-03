import Foundation

@Observable
final class HyperchargeModel {
    var isEnabled: Bool {
        didSet { save() }
    }

    var exclusionList: [String] {
        didSet { save() }
    }

    var dmgInstallEnabled: Bool {
        didSet { save() }
    }

    var dockToggleEnabled: Bool {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.exclusionList = defaults.stringArray(forKey: "exclusionList") ?? []
        self.dmgInstallEnabled = defaults.object(forKey: "dmgInstallEnabled") as? Bool ?? true
        self.dockToggleEnabled = defaults.object(forKey: "dockToggleEnabled") as? Bool ?? false
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
        defaults.set(dmgInstallEnabled, forKey: "dmgInstallEnabled")
        defaults.set(dockToggleEnabled, forKey: "dockToggleEnabled")
    }
}
