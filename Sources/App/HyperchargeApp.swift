import SwiftUI

@main
struct HyperchargeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = HyperchargeModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView(model: model, onOpenSettings: {
                appDelegate.showSettings()
            })
            .onAppear { appDelegate.model = model }
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
