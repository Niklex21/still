import Foundation
import SwiftUI

enum UsageEvent: String, CaseIterable {
    case imageAdded = "image_added"
    case imageDragged = "image_dragged"
    case imageCopied = "image_copied"
    case imageExported = "image_exported"
}

/// Count actions. Each request has a fresh ID so it cannot link a person's actions together.
final class UsageStats: ObservableObject {
    private let defaults: UserDefaults
    private let token: String?
    private let endpoint: URL?
    private let session: URLSession
    private static let consentKey = "shareUsageCounts.v1"
    @Published private(set) var enabled: Bool
    var available: Bool { token != nil && endpoint != nil }

    init(defaults: UserDefaults = .standard, info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         session: URLSession = URLSession(configuration: .ephemeral)) {
        self.defaults = defaults
        self.session = session
        let value = info["StillUsageToken"] as? String ?? ""
        token = value.hasPrefix("phc_") && value.count > 4 ? value : nil
        switch info["StillUsageRegion"] as? String {
        case "US": endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")
        case "EU": endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")
        default: endpoint = nil
        }
        enabled = defaults.bool(forKey: Self.consentKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = available && value
        defaults.set(enabled, forKey: Self.consentKey)
    }

    func record(_ event: UsageEvent) {
        guard let request = request(for: event) else { return }
        session.dataTask(with: request).resume()
    }

    func request(for event: UsageEvent) -> URLRequest? {
        guard enabled, let token, let endpoint else { return nil }
        let properties: [String: Any] = ["distinct_id": UUID().uuidString, "$process_person_profile": false, "$geoip_disable": true]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": token, "event": event.rawValue, "properties": properties])
        return request
    }
}

struct UsageConsent: View {
    @ObservedObject var usage: UsageStats
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Share usage counts", isOn: Binding(get: { usage.enabled }, set: usage.setEnabled))
            Text("Sends counts of adds, copies, drags, and exports to PostHog. Screenshots, text, and private captures stay out of these counts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
