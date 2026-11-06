import AppKit
import SnapShelfCore

private actor ControlledImageAnalyzer: ImageAnalyzing {
    struct Job { let revision: Int; let continuation: CheckedContinuation<VisualIndex, Error> }
    var jobs: [Job] = []
    var calls = 0
    var maxConcurrent = 0
    var ready = true
    func availability() -> VisualModelAvailability { ready ? .ready : .unavailable("Test model unavailable") }
    func setReady(_ value: Bool) { ready = value }
    func analyze(url: URL, revision: Int) async throws -> VisualIndex {
        calls += 1
        // Intentionally ignore cancellation to exercise late native responses.
        return try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(revision: revision, continuation: continuation))
            maxConcurrent = max(maxConcurrent, jobs.count)
        }
    }
    func count() -> Int { calls }
    func maximumConcurrent() -> Int { maxConcurrent }
    func complete(_ description: String) {
        let job = jobs.removeFirst()
        job.continuation.resume(returning: VisualIndex(summary: description, keywords: [], revision: job.revision))
    }
    func fail() { jobs.removeFirst().continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
}

enum VisualSearchSelfTest {
    @MainActor static func wait(_ message: String, seconds: Double = 5, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else { throw SelfTest.Failure(description: "Timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SelfTest.Failure(description: message) }
        print("PASS \(message)")
    }
    static func fixture(chart: Bool) -> CGImage {
        let context = CGContext(data: nil, width: 700, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 700, height: 500))
        if chart {
            context.setStrokeColor(NSColor.darkGray.cgColor); context.setLineWidth(4)
            context.move(to: CGPoint(x: 65, y: 440)); context.addLine(to: CGPoint(x: 65, y: 60)); context.addLine(to: CGPoint(x: 650, y: 60)); context.strokePath()
            context.setFillColor(NSColor.systemBlue.cgColor)
            for (i, height) in [120, 230, 180, 340].enumerated() {
                context.fill(CGRect(x: 105 + i * 140, y: 62, width: 85, height: height))
            }
        } else {
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: 200, y: 100, width: 300, height: 300))
        }
        return context.makeImage()!
    }
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Visual-QA-\(UUID())")
        let suite = "Still-Visual-QA-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let preferences = CapturePreferences(defaults: defaults), analyzer = ControlledImageAnalyzer()
        let store = try CaptureStore(root: root, preferences: preferences, visualAnalyzer: analyzer)
        let first = try store.add(fixture(chart: true), title: "First")
        try await wait("first analysis starts") { await analyzer.count() == 1 }
        let second = try store.add(fixture(chart: true), title: "Second")
        try store.saveEdit(first.id, image: fixture(chart: false))
        await analyzer.complete("Obsolete orange rectangle")
        try await wait("next image starts") { await analyzer.count() == 2 }
        try expect(!store.captures.contains(where: { $0.matches("obsolete") }), "An edit discards an in-flight description")
        await analyzer.complete("Blue bar chart")
        try await wait("edited image starts") { await analyzer.count() == 3 }
        await analyzer.complete("Red circle")
        try await wait("descriptions finish") { store.captures.allSatisfy(\.hasVisualIndex) && store.visualIndexingID == nil }
        try expect(store.captures.first(where: { $0.id == second.id })?.needsAttention == true, "Visual analysis does not consume or mark a screenshot viewed")
        try expect(try store.disk.load().allSatisfy(\.hasVisualIndex), "Visual descriptions survive library reload")
        try expect(store.captures.first(where: { $0.id == first.id })?.matches("red circle") == true, "The latest edited pixels become searchable")

        let deleted = try store.add(fixture(chart: true), title: "Deleted")
        try await wait("deleted job starts") { await analyzer.count() == 4 }
        store.captures.removeAll { $0.id == deleted.id }; store.persist()
        await analyzer.complete("Deleted image")
        try await wait("deleted job finishes") { store.visualIndexingID == nil }
        try expect(!store.captures.contains(where: { $0.id == deleted.id }), "An in-flight response cannot restore a deleted capture")

        let paused = try store.add(fixture(chart: true), title: "Paused")
        try await wait("paused job starts") { await analyzer.count() == 5 }
        preferences.visualSearchEnabled = false
        try await Task.sleep(for: .milliseconds(80))
        preferences.visualSearchEnabled = true
        try await Task.sleep(for: .milliseconds(80))
        try expect(await analyzer.count() == 5, "Resume waits for the canceled model response instead of starting concurrent inference")
        await analyzer.complete("Canceled result")
        try await wait("resume starts fresh analysis") { await analyzer.count() == 6 }
        try expect(store.captures.first(where: { $0.id == paused.id })?.visualIndex == nil, "Pausing discards a late model response")
        await analyzer.complete("Blue graph")
        try await wait("resumed job finishes") { store.visualIndexingID == nil }
        try expect(await analyzer.maximumConcurrent() == 1, "Only one image is analyzed at a time")

        let failed = try store.add(fixture(chart: true), title: "Retry")
        try await wait("failure job starts") { await analyzer.count() == 7 }
        await analyzer.fail()
        try await wait("failure is recorded") { store.visualFailures[failed.id] != nil && store.visualIndexingID == nil }
        try expect(store.error == nil, "A model failure leaves capture and OCR usable without an error popup")
        store.retryVisualIndexing()
        try await wait("retry job starts") { await analyzer.count() == 8 }
        await analyzer.complete("Blue chart")
        try await wait("retry completes") { store.captures.first(where: { $0.id == failed.id })?.hasVisualIndex == true }
        try expect(store.visualFailures.isEmpty, "Retry recovers a failed visual index")

        preferences.visualSearchEnabled = false
        try await Task.sleep(for: .milliseconds(80))
        let recovered = try CaptureStore(root: root, preferences: preferences, visualAnalyzer: analyzer, startVisualIndexing: false)
        try expect(recovered.filtered.count == 4, "Restart loads the existing library while analysis is paused")
        await analyzer.setReady(false)
        preferences.visualSearchEnabled = true
        let unavailable = try store.add(fixture(chart: true), title: "Unavailable")
        try await wait("model availability check") { !store.visualAvailability.isReady }
        try expect(await analyzer.count() == 8, "An unavailable model does not attempt inference")
        await analyzer.setReady(true)
        store.retryVisualIndexing()
        try await wait("model readiness recovers") { await analyzer.count() >= 9 }
        await analyzer.complete("Blue bars")
        try await wait("availability recovery completes") { store.captures.first(where: { $0.id == unavailable.id })?.hasVisualIndex == true }
        preferences.visualSearchEnabled = false
        print("VISUAL PIPELINE SELF-TEST PASSED")
    }
    @MainActor static func runModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Still-Visual-Model-QA-\(UUID())")
        let suite = "Still-Visual-Model-QA-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let preferences = CapturePreferences(defaults: defaults)
        preferences.visualSearchEnabled = true
        let analyzer = AppleImageAnalyzer()
        try expect(await analyzer.availability() == .ready, "Apple's on-device vision model is available")
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "--image"), arguments.count > position + 1 {
            do {
                _ = try await analyzer.analyze(url: URL(fileURLWithPath: arguments[position + 1]), revision: 0)
                print("PASS Supplied image can be analyzed locally")
            } catch {
                throw SelfTest.Failure(description: AppleImageAnalyzer.failureDescription(error))
            }
            return
        }
        let store = try CaptureStore(root: root, preferences: preferences, visualAnalyzer: analyzer)
        let start = Date()
        let chart = try store.add(fixture(chart: true), title: "Sample A")
        try await wait("real chart analysis", seconds: 60) { store.captures.first(where: { $0.id == chart.id })?.hasVisualIndex == true || !store.visualFailures.isEmpty }
        let indexed = store.captures.first(where: { $0.id == chart.id })!
        print("MODEL CHART: \(indexed.visualSearchText)")
        try expect(indexed.matches("blue") && (indexed.matches("chart") || indexed.matches("graph")), "Real image content becomes searchable without OCR or filename hints")
        try expect(indexed.needsAttention, "Real inference leaves the capture queue unchanged")
        try store.saveEdit(chart.id, image: fixture(chart: false))
        try expect(!store.captures.first(where: { $0.id == chart.id })!.matches("blue chart"), "Editing immediately removes obsolete visual search content")
        try await wait("real edited image analysis", seconds: 60) { store.captures.first(where: { $0.id == chart.id })?.hasVisualIndex == true || !store.visualFailures.isEmpty }
        let edited = store.captures.first(where: { $0.id == chart.id })!
        print("MODEL SHAPE: \(edited.visualSearchText)")
        try expect(edited.matches("red circle"), "Real analysis recognizes the edited shape")
        let iconURL = Bundle.main.resourceURL!.appendingPathComponent("AppIcon.png")
        let icon = try store.add(Imaging.load(iconURL), title: "Sample B")
        try await wait("real icon analysis", seconds: 60) { store.captures.first(where: { $0.id == icon.id })?.hasVisualIndex == true || !store.visualFailures.isEmpty }
        let iconCapture = store.captures.first(where: { $0.id == icon.id })!
        print("MODEL ICON: \(iconCapture.visualSearchText)")
        try expect(iconCapture.matches("blue") && iconCapture.matches("icon"), "Real analysis recognizes a detailed app icon")
        try expect(try store.disk.load().allSatisfy(\.hasVisualIndex), "Real model results persist for Still and Raycast search")
        preferences.visualSearchEnabled = false
        print("VISUAL MODEL SELF-TEST PASSED in \(String(format: "%.1f", Date().timeIntervalSince(start))) seconds")
    }
}
