import SwiftUI
@preconcurrency import ApplicationServices

struct MenuPopoverView: View {
    @Bindable var model: HyperchargeModel
    var onOpenSettings: () -> Void = {}
    private let accessibility = AccessibilityService.shared

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $model.isEnabled) {
                Text("Quit App When Last Window Closes")
            }
            .toggleStyle(.switch)
            .padding()

            Divider()

            Button("Excluded Apps…") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onOpenSettings()
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Image(systemName: accessibility.isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(accessibility.isTrusted ? .green : .red)
                    Text(accessibility.isTrusted ? "Accessibility Granted" : "Accessibility Not Granted")
                    Spacer()
                }

                if !accessibility.isTrusted {
                    Button("Grant Permission") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                        AXIsProcessTrustedWithOptions(opts)
                        accessibility.isTrusted = AXIsProcessTrusted()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            Button("About Hypercharge") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Button("Quit Hypercharge") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .keyboardShortcut("q")
        }
        .frame(width: 280)
    }
}
