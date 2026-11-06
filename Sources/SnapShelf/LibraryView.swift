import SwiftUI
import SnapShelfCore

struct LibraryView: View {
    @ObservedObject var store: CaptureStore
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var showFilters = false
    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                List(selection: Binding<String?>(get: { store.filter }, set: { if let value = $0 { store.filter = value } })) {
                    sidebarRow("All Screenshots", icon: "photo.on.rectangle", count: store.captures.count).tag("all")
                    sidebarRow("Queue", icon: "tray", count: store.shelf.count).tag("shelf")
                    sidebarRow("Favorites", icon: "star", count: store.captures.filter(\.favorite).count).tag("favorites")
                }
                .listStyle(.sidebar).frame(width: 190)
                Divider()
            }
            VStack(spacing: 0) {
                ErrorBanner(store: store)
                HStack(spacing: 12) {
                    Button { showFilters.toggle() } label: { Image(systemName: store.historyFilters.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }.help("Filter history")
                        .popover(isPresented: $showFilters) { HistoryFilterView(store: store).frame(width: 330).padding(16) }
                    Toggle("Smart Search", isOn: $store.semanticSearchEnabled).toggleStyle(.checkbox).font(.caption).help("Use on-device sentence similarity alongside exact matches")
                    if store.searching { ProgressView().controlSize(.mini) }
                    if !store.query.isEmpty && !store.searching && store.semanticSearchEnabled && !store.semanticAvailable { Text("Exact search · system language model unavailable").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Menu { ForEach(savedProjects, id: \.id) { project in Button(project.title) { WalkthroughController.show(items: [], store: store, project: project) } } } label: { Image(systemName: "list.number") }.help("Saved walkthroughs")
                    if selecting {
                        Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                        Button("Create Walkthrough…") { WalkthroughController.show(items: store.captures.filter { selected.contains($0.id) }, store: store) }.disabled(selected.isEmpty || selected.count > 50)
                    }
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }
                }.buttonStyle(.borderless).padding(.horizontal, 22).frame(height: 40)
                Divider()
                if store.filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: store.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                        Text(store.query.isEmpty ? "No screenshots yet" : "No results").font(.system(size: 16, weight: .semibold))
                        if store.query.isEmpty {
                            Button("Capture Screenshot") { AppDelegate.shared.capture(.region) }.controlSize(.large)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 195, maximum: 280), spacing: 16)], spacing: 16) {
                            ForEach(store.filtered) { item in
                                CaptureCard(store: store, item: item)
                                    .overlay { if selecting { RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.01)).onTapGesture { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } } }
                                    .overlay(alignment: .topLeading) { if selecting { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(selected.contains(item.id) ? accent : .secondary).padding(10).allowsHitTesting(false) } }
                            }
                        }.padding(22)
                    }
                }
                HStack {
                    Text("\(store.filtered.count) \(store.filtered.count == 1 ? "screenshot" : "screenshots")")
                    if !store.indexing.isEmpty || store.visualIndexingID != nil {
                        Text("·"); ProgressView().controlSize(.mini)
                        Text(store.visualIndexingID != nil ? "Analyzing images" : "Indexing text")
                    }
                    Spacer()
                    Button { AppDelegate.shared.showShelf() } label: { Image(systemName: "tray") }.buttonStyle(.plain).help("Show shelf")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 30)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { importDrop($0, store: store) }
    }
    var savedProjects: [Walkthrough] {
        let folder = store.disk.root.appendingPathComponent("Walkthroughs")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let project = try? JSONDecoder().decode(Walkthrough.self, from: data), project.version == 1 else { return nil }; return project
        }.sorted { $0.title < $1.title }
    }
    func sidebarRow(_ title: String, icon: String, count: Int) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary) }.padding(.vertical, 4)
    }
}

struct HistoryFilterView: View {
    @ObservedObject var store: CaptureStore
    var body: some View {
        Form {
            Picker("Application", selection: $store.historyFilters.application) {
                Text("Any").tag("")
                ForEach(Array(Set(store.captures.compactMap { $0.metadata?.application })).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Capture type", selection: $store.historyFilters.kind) {
                Text("Any").tag("")
                ForEach(Array(Set(store.captures.compactMap { $0.metadata?.kind })).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Captured", selection: $store.historyFilters.days) { Text("Any time").tag(0); Text("Last 24 hours").tag(1); Text("Last 7 days").tag(7); Text("Last 30 days").tag(30) }
            TextField("Tag", text: $store.historyFilters.tag)
            Toggle("Contains text", isOn: $store.historyFilters.hasText)
            Button("Reset Filters") { store.historyFilters = HistoryFilters() }.disabled(!store.historyFilters.active)
        }
    }
}
