import AppKit
import SwiftUI
import SnapShelfCore

final class DescriptionController: NSWindowController, NSWindowDelegate {
    let captureID: UUID
    var onClose: (() -> Void)?
    init(id: UUID, store: CaptureStore) {
        captureID = id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Image Description"
        window.minSize = NSSize(width: 380, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: DescriptionView(store: store, id: id))
        host.sizingOptions = []
        window.contentView = host
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct DescriptionView: View {
    @ObservedObject var store: CaptureStore
    @ObservedObject private var preferences: CapturePreferences
    let id: UUID
    @State private var copied = false
    @State private var notes = ""
    @State private var tags = ""
    @State private var sourceURL = ""
    @State private var metadataSaved = false
    private var item: Capture? { store.captures.first { $0.id == id } }
    private var description: VisualIndex? { item.flatMap { $0.hasVisualIndex ? $0.visualIndex : nil } }
    init(store: CaptureStore, id: UUID) {
        self.store = store; self.id = id; preferences = store.preferences
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let item {
                HStack(spacing: 14) {
                    if let thumbnail = store.thumbnail(item) {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .frame(width: 84, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let description {
                            Text(description.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if !description.keywords.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Search tags").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    Text(description.keywords.joined(separator: " · "))
                                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        } else {
                            pendingDescription
                        }
                        Divider()
                        if let metadata = item.metadata {
                            if let application = metadata.application { LabeledContent("Application", value: application).font(.caption) }
                            if let kind = metadata.kind { LabeledContent("Capture type", value: kind).font(.caption) }
                            if let title = metadata.windowTitle, !title.isEmpty { Text(title).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        TextField("Source URL", text: $sourceURL).textFieldStyle(.roundedBorder)
                        TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder)
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                        Button(metadataSaved ? "Saved" : "Save Details") {
                            store.update(id) { item in
                                var metadata = item.metadata ?? CaptureMetadata()
                                metadata.notes = notes; metadata.sourceURL = sourceURL.isEmpty ? nil : sourceURL
                                metadata.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                                item.metadata = metadata
                            }; metadataSaved = true
                        }
                        DisclosureGroup("Recognized text") { Text(item.text.isEmpty ? "No text detected" : item.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Label(description == nil ? "On-device analysis" : "Generated on this Mac", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let description {
                        Button {
                            let text = description.summary + (description.keywords.isEmpty ? "" : "\n\n" + description.keywords.joined(separator: ", "))
                            store.pasteboard.clearContents()
                            copied = store.pasteboard.setString(text, forType: .string)
                        } label: {
                            Label(copied ? "Copied" : "Copy Description", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            } else {
                Text("This image is no longer in your library.").foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { notes = item?.metadata?.notes ?? ""; tags = item?.metadata?.tags.joined(separator: ", ") ?? ""; sourceURL = item?.metadata?.sourceURL ?? "" }
            .onChange(of: notes) { _, _ in metadataSaved = false }.onChange(of: tags) { _, _ in metadataSaved = false }.onChange(of: sourceURL) { _, _ in metadataSaved = false }
            .onChange(of: description) { _, _ in copied = false }
    }
    @ViewBuilder private var pendingDescription: some View {
        if item?.isPrivate == true {
            Text("Private capture · image analysis is off").foregroundStyle(.secondary)
        } else if !preferences.visualSearchEnabled {
            Text("Image analysis is paused.").foregroundStyle(.secondary)
            Button("Resume Analysis") { preferences.visualSearchEnabled = true }
        } else if store.visualFailures[id] != nil {
            Text("No description is available for this image.").foregroundStyle(.secondary)
            Button("Retry Analysis") { store.retryVisualIndexing(for: id) }
        } else if !store.visualAvailability.isReady {
            Text(store.visualAvailability.explanation).foregroundStyle(.secondary)
            Button("Try Again") { store.retryVisualIndexing(for: id) }
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(store.visualIndexingID == id ? "Analyzing image…" : "Waiting for image analysis…").foregroundStyle(.secondary)
            }
        }
    }
}
