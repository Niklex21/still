import AppKit
import SwiftUI
import SnapShelfCore

enum StillSupport {
    static var bugReport: URL {
        var url = URLComponents(string: "https://github.com/Niklex21/still/issues/new")!
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "source"
        let build = info["CFBundleVersion"] as? String ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        url.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: "Still \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        ]
        return url.url!
    }
}

struct GettingStarted: View {
    @ObservedObject var shortcuts: GlobalShortcutManager
    @ObservedObject var usage: UsageStats
    let settings: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder").font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Still").font(.title2.bold())
                    Text("Find Still in your menu bar.").foregroundStyle(.secondary)
                }
            }
            Divider()
            row("viewfinder", "Capture a region", "Drag across the area you want to keep.", .region)
            row("square.on.square", "Share a screenshot", "Drag the preview into another app, or hover to copy.", .copySharingHovered)
            row("rectangle.stack", "Reopen the shelf", "Browse recent captures and expand into History.", .shelf)
            if usage.available {
                Divider()
                UsageConsent(usage: usage)
            }
            Divider()
            HStack {
                Button("Customize Shortcuts…", action: settings).buttonStyle(.link)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ action: ShortcutAction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    if let binding = shortcuts.bindings[action], shortcuts.errors[action] == nil {
                        Text(binding.displayName).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
