import SwiftUI

struct PrivacySettings: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject var preferences: CapturePreferences
    var body: some View {
        Form {
            Section("Private captures") {
                Text("Private Region captures stay out of History, OCR indexing, and image analysis. They use temporary local files for drag and drop; those files are cleaned after handling or when Still quits.").font(.callout).foregroundStyle(.secondary)
                Button("Capture Private Region…") { AppDelegate.shared?.privateRegionAction() }
            }
            Section("History retention") {
                Picker("Keep screenshots", selection: $preferences.retentionDays) {
                    Text("Forever").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }
                Text("Expired images move to Trash. Favorites, pins, queued screenshots, and walkthrough sources are protected. Cleanup is off by default.").font(.caption).foregroundStyle(.secondary)
                Button("Clean Up Now") { store.cleanupExpiredCaptures() }.disabled(preferences.retentionDays == 0)
                if !store.cleanupStatus.isEmpty { Text(store.cleanupStatus).font(.caption).foregroundStyle(.secondary) }
            }
            if let usage = store.usage, usage.available {
                Section("Usage statistics") { UsageConsent(usage: usage) }
            }
            Section("Stored originals") {
                Text("Redaction protects the rendered image you copy or export. Originals and editable bases remain in your local library until you move the capture to Trash.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
