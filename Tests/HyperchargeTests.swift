import Testing
import Foundation
@testable import Hypercharge

func freshModel() -> HyperchargeModel {
    let domain = "com.hypercharge.test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.removePersistentDomain(forName: domain)
    return HyperchargeModel(userDefaults: defaults)
}

struct HyperchargeTests {

    @Test func modelStartsWithFeatureEnabled() {
        let model = freshModel()
        #expect(model.isEnabled == true)
        #expect(model.exclusionList.isEmpty)
    }

    @Test func toggleExclusionAddsAndRemoves() {
        let model = freshModel()
        #expect(model.isExcluded("com.apple.Safari") == false)

        model.toggleExclusion("com.apple.Safari")
        #expect(model.isExcluded("com.apple.Safari"))
        #expect(model.exclusionList == ["com.apple.Safari"])

        model.toggleExclusion("com.apple.Safari")
        #expect(model.isExcluded("com.apple.Safari") == false)
        #expect(model.exclusionList.isEmpty)
    }

    @Test func exclusionListHandlesMultipleApps() {
        let model = freshModel()
        model.toggleExclusion("com.apple.Safari")
        model.toggleExclusion("com.apple.Mail")
        model.toggleExclusion("com.apple.Finder")

        #expect(model.exclusionList.count == 3)
        #expect(model.isExcluded("com.apple.Safari"))
        #expect(model.isExcluded("com.apple.Mail"))
        #expect(model.isExcluded("com.apple.Finder"))
    }

    @Test func isEnabledPersistsInMemory() {
        let model = freshModel()
        #expect(model.isEnabled == true)

        model.isEnabled = false
        #expect(model.isEnabled == false)

        model.isEnabled = true
        #expect(model.isEnabled)
    }
}
