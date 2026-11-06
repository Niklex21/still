import AppKit
import SwiftUI
import SnapShelfCore
import UniformTypeIdentifiers
import Combine

final class CaptureStore: ObservableObject {
    @Published var captures: [Capture] = []
    @Published var query = ""
    @Published var filter = "all"
    @Published var historyFilters = HistoryFilters()
    @Published var semanticSearchEnabled = true
    @Published private(set) var searchIDs: [UUID] = []
    @Published private(set) var searching = false
    @Published private(set) var semanticAvailable = false
    private let searchEngine = SemanticSearch()
    private let searchQueue = DispatchQueue(label: "Still.SemanticSearch", qos: .userInitiated)
    private var searchSubscription: AnyCancellable?
    private var searchGeneration = 0
    @Published var sidebarVisible = true
    @Published var error: String?
    @Published var indexing: Set<UUID> = []
    @Published private(set) var visualAvailability: VisualModelAvailability = .checking
    @Published private(set) var visualIndexingID: UUID?
    @Published private(set) var visualFailures: [UUID: Int] = [:]
    @Published private(set) var visualFailureReason: String?
    private let visualAnalyzer: any ImageAnalyzing
    private let automaticallyIndexVisuals: Bool
    private var visualTask: Task<Void, Never>?
    private var visualRetryTask: Task<Void, Never>?
    private var visualGeneration = 0
    private var visualPreferenceSubscription: AnyCancellable?
    @Published private(set) var copiedID: UUID?
    private(set) var activeDragID: UUID?
    private var copyFeedbackTask: DispatchWorkItem?
    let disk: LibraryDisk
    let preferences: CapturePreferences
    @Published private(set) var feedbackMessage = "Copied"
    @Published private(set) var feedbackDetail: String?
    private let ocrQueue = DispatchQueue(label: "Still.OCR", qos: .utility)
    private let thumbnails = NSCache<NSString, NSImage>()
    var onImport: (() -> Void)?
    var onPinsChanged: (() -> Void)?
    var shelf: [Capture] { captures.filter(\.onShelf) }
    var compactShelf: CompactShelfContents { CompactShelfContents(captures: captures) }
    var pendingCount: Int { captures.filter(\.needsAttention).count }
    var filtered: [Capture] {
        let items = captures.filter { (filter != "favorites" || $0.favorite) && (filter != "shelf" || $0.onShelf) && historyFilters.includes($0) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return searchIDs.compactMap { byID[$0] }
    }
    func refreshSearch() {
        searchGeneration += 1
        let generation = searchGeneration, items = captures, text = query, smart = semanticSearchEnabled
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchIDs = []; searching = false; return }
        searching = true
        searchQueue.async { [weak self] in
            guard let self else { return }
            let ids = self.searchEngine.rank(items, query: text, semantic: smart).map(\.id)
            let available = self.searchEngine.available
            DispatchQueue.main.async {
                guard self.searchGeneration == generation else { return }
                self.searchIDs = ids; self.semanticAvailable = available; self.searching = false
            }
        }
    }
    init(root: URL, preferences: CapturePreferences = CapturePreferences(), visualAnalyzer: any ImageAnalyzing = AppleImageAnalyzer(), startVisualIndexing: Bool = true) throws {
        self.preferences = preferences
        self.visualAnalyzer = visualAnalyzer
        automaticallyIndexVisuals = startVisualIndexing && !ProcessInfo.processInfo.arguments.contains("--self-test")
        disk = try LibraryDisk(root: root)
        captures = try disk.load()
        // Older libraries had no separate current-batch membership. Only their
        // unread captures can enter the current batch during migration.
        if captures.contains(where: { $0.inPreview == nil }) {
            for i in captures.indices where captures[i].inPreview == nil {
                if captures[i].reviewedAt != nil { captures[i].onShelf = false }
                captures[i].inPreview = captures[i].needsAttention
            }
            normalizeCurrentPreviews()
            try disk.save(captures)
        }
        searchSubscription = Publishers.CombineLatest3($query, $captures, $semanticSearchEnabled).debounce(for: .milliseconds(180), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.refreshSearch() }
        thumbnails.countLimit = 150
        // Resume indexing interrupted by a quit or crash, including older indexes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for item in self.captures where item.indexed != true && !self.indexing.contains(item.id) {
                if let image = try? Imaging.load(self.disk.url(item)) { self.index(item, image: image) }
            }
            self.startVisualIndexing()
        }
        visualPreferenceSubscription = preferences.$visualSearchEnabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.retryVisualIndexing() }
            else {
                self.visualGeneration += 1
                self.visualTask?.cancel()
                self.visualRetryTask?.cancel(); self.visualRetryTask = nil
            }
        }
    }
    func startVisualIndexing() {
        guard automaticallyIndexVisuals, preferences.visualSearchEnabled, visualTask == nil else { return }
        visualRetryTask?.cancel(); visualRetryTask = nil
        let generation = visualGeneration
        visualTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.visualIndexingID = nil
                self.visualTask = nil
                // A canceled job must finish before another starts, even if the
                // user pauses and resumes while the native model is responding.
                if generation != self.visualGeneration { self.startVisualIndexing() }
            }
            self.visualAvailability = await self.visualAnalyzer.availability()
            guard !Task.isCancelled, self.visualAvailability.isReady else {
                if !Task.isCancelled { self.scheduleVisualRetry() }
                return
            }
            while !Task.isCancelled && self.preferences.visualSearchEnabled {
                guard let item = self.captures.first(where: { !$0.hasVisualIndex && self.visualFailures[$0.id] != $0.revision }) else { break }
                self.visualIndexingID = item.id
                do {
                    let result = try await self.visualAnalyzer.analyze(url: self.disk.url(item), revision: item.revision)
                    guard !Task.isCancelled, generation == self.visualGeneration, self.preferences.visualSearchEnabled else { break }
                    // Deleted images never return; edits always invalidate the
                    // in-flight result. Metadata writes do not mark images viewed.
                    if let i = self.captures.firstIndex(where: { $0.id == item.id && $0.revision == item.revision }),
                       result.revision == item.revision, result.version == VisualIndex.currentVersion {
                        self.captures[i].visualIndex = result
                        self.visualFailures.removeValue(forKey: item.id)
                        self.persist()
                    }
                } catch {
                    if Task.isCancelled { break }
                    if self.captures.contains(where: { $0.id == item.id && $0.revision == item.revision }) {
                        self.visualFailures[item.id] = item.revision
                        self.visualFailureReason = AppleImageAnalyzer.failureDescription(error)
                    }
                    self.visualAvailability = await self.visualAnalyzer.availability()
                    if !self.visualAvailability.isReady { self.scheduleVisualRetry(); break }
                }
                self.visualIndexingID = nil
                // Give captures, drags, and other apps breathing room during backfill.
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    private func scheduleVisualRetry() {
        guard automaticallyIndexVisuals, preferences.visualSearchEnabled else { return }
        visualRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            // Model readiness can change while Apple downloads its system assets.
            self.visualFailures.removeAll()
            self.startVisualIndexing()
        }
    }
    func retryVisualIndexing() {
        visualFailures.removeAll()
        visualRetryTask?.cancel(); visualRetryTask = nil
        visualGeneration += 1
        if let visualTask { visualTask.cancel() } else { startVisualIndexing() }
    }
    func retryVisualIndexing(for id: UUID) {
        visualFailures.removeValue(forKey: id)
        startVisualIndexing()
    }
    func persist() { do { try disk.save(captures) } catch { self.error = "Could not save the library: \(error.localizedDescription)" } }
    func update(_ id: UUID, _ change: (inout Capture) -> Void) {
        guard let i = captures.firstIndex(where: { $0.id == id }) else { return }
        let previousPin = captures[i].pinnedAt
        let wasOnShelf = captures[i].onShelf
        change(&captures[i])
        if !captures[i].onShelf {
            thumbnails.removeObject(forKey: "\(captures[i].id)-\(captures[i].revision)" as NSString)
            captures[i].inPreview = false
            if captures[i].reviewedAt == nil { captures[i].reviewedAt = Date() }
        } else if !wasOnShelf { captures[i].inPreview = true }
        normalizeCurrentPreviews()
        persist()
        if previousPin != captures[i].pinnedAt { onPinsChanged?() }
    }
    private func normalizeCurrentPreviews() {
        var count = 0
        for i in captures.indices where captures[i].isCurrentPreview {
            count += 1
            if count > 3 { captures[i].inPreview = false }
        }
    }
    func beginShelfDrag(_ id: UUID) { activeDragID = id }
    func finishShelfDrag(_ id: UUID, succeeded: Bool) {
        activeDragID = nil
        guard succeeded else { return }
        update(id) { $0.onShelf = false }
    }
    func dismissCurrentPreviews() {
        let ids = Set(compactShelf.recent.map(\.id))
        guard !ids.isEmpty else { return }
        let now = Date()
        var next = captures
        for i in next.indices where ids.contains(next[i].id) {
            thumbnails.removeObject(forKey: "\(next[i].id)-\(next[i].revision)" as NSString)
            next[i].onShelf = false; next[i].inPreview = false
            if next[i].reviewedAt == nil { next[i].reviewedAt = now }
        }
        captures = next; persist()
    }
    func togglePin(_ id: UUID) {
        guard let item = captures.first(where: { $0.id == id }) else { return }
        guard item.isPinned || FileManager.default.fileExists(atPath: disk.url(item).path) else { error = "The image file is missing."; return }
        update(id) {
            $0.pinnedAt = $0.isPinned ? nil : Date()
            if $0.isPinned { $0.onShelf = false; if $0.reviewedAt == nil { $0.reviewedAt = Date() } }
        }
    }
    func copyText(_ item: Capture) {
        guard !item.text.isEmpty else { error = "No recognized text is available for this screenshot."; return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(item.text, forType: .string) { showCopyConfirmation(item.id); consume(item.id) }
    }
    func consume(_ id: UUID) { update(id) { $0.onShelf = false } }
    @discardableResult func prepareUpload(_ item: Capture) -> Bool {
        let url = disk.url(item)
        guard FileManager.default.fileExists(atPath: url.path) else { error = "The image file is missing."; return false }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.path, forType: .string) else { error = "Could not copy the file path."; return false }
        NSPasteboard.general.setString(url.absoluteString, forType: .fileURL)
        markReviewed(item.id)
        showCopyConfirmation(item.id, message: "Path copied", detail: "In the file chooser: ⌘⇧G, then ⌘V")
        return true
    }
    func savePNG(_ item: Capture, to url: URL) throws {
        let data = try Data(contentsOf: disk.url(item))
        try data.write(to: url, options: .atomic)
        consume(item.id)
        showCopyConfirmation(item.id, message: "Saved")
    }
    func markReviewed(_ id: UUID) {
        markReviewed(Set([id]))
    }
    func markReviewed(_ ids: Set<UUID>) {
        var next = captures
        let now = Date()
        var changed = false
        for index in next.indices where ids.contains(next[index].id) && next[index].reviewedAt == nil {
            next[index].reviewedAt = now; changed = true
        }
        if changed { captures = next; persist() }
    }
    func showInFinder(_ item: Capture) {
        markReviewed(item.id)
        NSWorkspace.shared.activateFileViewerSelecting([disk.url(item)])
    }
    func thumbnail(_ item: Capture) -> NSImage? {
        let key = "\(item.id)-\(item.revision)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(disk.url(item) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 700] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: cg, size: .zero); thumbnails.setObject(result, forKey: key); return result
    }
    @discardableResult func add(_ image: CGImage, title: String? = nil, metadata: CaptureMetadata? = nil) throws -> Capture {
        guard image.width <= 30_000, image.height <= 30_000, image.width * image.height <= 150_000_000 else { throw Imaging.ImageError.tooLarge }
        let name = title ?? "Screenshot \(Date().formatted(date: .abbreviated, time: .shortened))"
        var item = Capture(title: name, width: image.width, height: image.height); item.metadata = metadata
        let data = try Imaging.png(image)
        try data.write(to: disk.url(item, original: true), options: .atomic)
        try data.write(to: disk.url(item), options: .atomic)
        var next = captures; next.insert(item, at: 0)
        // Once a capture rolls into the older stack it never automatically
        // refills an empty slot in the current batch.
        var count = 0
        for i in next.indices where next[i].isCurrentPreview {
            count += 1
            if count > 3 { next[i].inPreview = false }
        }
        try disk.save(next); captures = next
        index(item, image: image); startVisualIndexing(); onImport?(); return item
    }
    func importURLs(_ urls: [URL]) {
        for url in urls {
            do { try add(Imaging.load(url), title: url.deletingPathExtension().lastPathComponent, metadata: CaptureMetadata(kind: "Import")) }
            catch { self.error = error.localizedDescription }
        }
    }
    func index(_ item: Capture, image: CGImage) {
        indexing.insert(item.id)
        let revision = item.revision
        ocrQueue.async {
            let result = Result { (try Imaging.recognize(image), try Imaging.recognizeRegions(image)) }
            DispatchQueue.main.async {
                guard let current = self.captures.first(where: { $0.id == item.id }) else { self.indexing.remove(item.id); return }
                guard current.revision == revision else { return }
                self.indexing.remove(item.id)
                switch result {
                case .success(let result): self.update(item.id) { $0.text = result.0; $0.textRegions = result.1; $0.indexed = true }
                case .failure(let error): self.error = "Text recognition failed: \(error.localizedDescription). The image is saved."
                }
            }
        }
    }
    func saveEdit(_ id: UUID, image: CGImage, document: EditDocument? = nil, base: CGImage? = nil) throws {
        guard let i = captures.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        guard (document == nil) == (base == nil) else { throw CocoaError(.fileWriteInvalidFileName) }
        let item = captures[i], url = disk.url(item), previous = try Data(contentsOf: url)
        if let document, let base {
            guard document.version == 1, document.baseFilename.hasPrefix("\(id)-edit-base-"), document.baseFilename.hasSuffix(".png"), URL(fileURLWithPath: document.baseFilename).lastPathComponent == document.baseFilename, !FileManager.default.fileExists(atPath: disk.images.appendingPathComponent(document.baseFilename).path) else { throw CocoaError(.fileWriteInvalidFileName) }
            try Imaging.png(base).write(to: disk.images.appendingPathComponent(document.baseFilename), options: .atomic)
        }
        var next = captures
        next[i].width = image.width; next[i].height = image.height; next[i].text = ""; next[i].textRegions = nil
        next[i].indexed = false; next[i].visualIndex = nil; next[i].revision += 1; next[i].onShelf = false; next[i].inPreview = false
        next[i].reviewedAt = next[i].reviewedAt ?? Date(); next[i].editDocument = document
        do {
            try Imaging.png(image).write(to: url, options: .atomic)
            try disk.save(next)
        } catch {
            try? previous.write(to: url, options: .atomic)
            if let document { try? FileManager.default.removeItem(at: disk.images.appendingPathComponent(document.baseFilename)) }
            throw error
        }
        captures = next
        if let previousDocument = item.editDocument, previousDocument.baseFilename != document?.baseFilename,
           URL(fileURLWithPath: previousDocument.baseFilename).lastPathComponent == previousDocument.baseFilename,
           previousDocument.baseFilename.hasPrefix("\(id)-edit-base") {
            try? FileManager.default.removeItem(at: disk.images.appendingPathComponent(previousDocument.baseFilename))
        }
        index(next[i], image: image)
        visualFailures.removeValue(forKey: id); startVisualIndexing(); onPinsChanged?()
    }
    @discardableResult func copy(_ item: Capture) -> Bool {
        guard let image = NSImage(contentsOf: disk.url(item)) else { error = "The image file is missing."; return false }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else { error = "Could not copy the image. Please try again."; return false }
        showCopyConfirmation(item.id)
        consume(item.id)
        return true
    }
    private func showCopyConfirmation(_ id: UUID, message: String = "Copied", detail: String? = nil) {
        copyFeedbackTask?.cancel()
        feedbackMessage = message; feedbackDetail = detail
        copiedID = id
        let task = DispatchWorkItem { [weak self] in self?.copiedID = nil }
        copyFeedbackTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 1.4 : 3.0), execute: task)
    }
    func paste() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { importURLs(urls); return }
        guard let image = NSImage(pasteboard: .general), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { error = "Copy an image first, then paste it here."; return }
        do { try add(cg, title: "Pasted image", metadata: CaptureMetadata(kind: "Paste")) } catch { self.error = error.localizedDescription }
    }
    func chooseImages() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }
    func export(_ item: Capture) { ExportController.show(item, store: self) }
    func delete(_ item: Capture) {
        let alert = NSAlert(); alert.messageText = "Move this screenshot to the Trash?"
        alert.informativeText = "The edited image and its original will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bases = try FileManager.default.contentsOfDirectory(at: disk.images, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("\(item.id)-edit-base") && $0.pathExtension == "png" }
            for url in [disk.url(item), disk.url(item, original: true)] + bases where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            captures.removeAll { $0.id == item.id }; visualFailures.removeValue(forKey: item.id); persist(); onPinsChanged?()
        } catch { self.error = error.localizedDescription }
    }
}

struct ErrorBanner: View {
    @ObservedObject var store: CaptureStore
    var body: some View {
        if let error = store.error {
            HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(error).font(.callout); Spacer(); Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                .padding(12).background(Color.orange.opacity(0.16))
        }
    }
}
