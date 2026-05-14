import SwiftUI

struct SettingsView: View {
    @Bindable var model: HyperchargeModel
    @State private var showingAppPicker = false

    var body: some View {
        Form {
            Section {
                Toggle("Quit app when last window closes", isOn: $model.isEnabled)
            }

            Section("Excluded Apps") {
                if model.exclusionList.isEmpty {
                    Text("No apps excluded")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.exclusionList, id: \.self) { bundleId in
                    HStack(spacing: 8) {
                        appIcon(for: bundleId)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(appName(for: bundleId))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.toggleExclusion(bundleId)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from exclusion list")
                    }
                }

                Button("Add App…") {
                    showingAppPicker = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView(excluded: model.exclusionList) { bundleId in
                if !model.isExcluded(bundleId) {
                    model.toggleExclusion(bundleId)
                }
            }
        }
    }

    private func appIcon(for bundleId: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: url),
           let iconName = bundle.infoDictionary?["CFBundleIconFile"] as? String {
            let iconURL = url.appendingPathComponent("Contents/Resources/\(iconName)")
            if let img = NSImage(contentsOf: iconURL) { return Image(nsImage: img) }
            let withIcns = url.appendingPathComponent("Contents/Resources/\(iconName).icns")
            if let img = NSImage(contentsOf: withIcns) { return Image(nsImage: img) }
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path ?? ""))
    }

    private func appName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingLastPathComponent().lastPathComponent == "Applications"
                ? url.deletingPathExtension().lastPathComponent
                : (Bundle(url: url)?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
        }
        return bundleId
    }
}

struct AppPickerView: View {
    let excluded: [String]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppInfo] = []
    @State private var search = ""

    var filtered: [AppInfo] {
        if search.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose App to Exclude")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)

            List(filtered) { app in
                Button {
                    onSelect(app.bundleId)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.bundleId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if excluded.contains(app.bundleId) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(excluded.contains(app.bundleId))
            }
        }
        .frame(width: 360, height: 480)
        .task { apps = loadApps() }
    }

    private func loadApps() -> [AppInfo] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities",
                    "\(NSHomeDirectory())/Applications"]
        var result: [AppInfo] = []
        var seen = Set<String>()

        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = "\(dir)/\(entry)"
                guard let bundle = Bundle(path: path),
                      let bundleId = bundle.bundleIdentifier,
                      !seen.contains(bundleId) else { continue }
                seen.insert(bundleId)
                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? entry.replacingOccurrences(of: ".app", with: "")
                let icon = NSWorkspace.shared.icon(forFile: path)
                result.append(AppInfo(name: name, bundleId: bundleId, icon: icon))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AppInfo: Identifiable {
    let id = UUID()
    let name: String
    let bundleId: String
    let icon: NSImage
}
