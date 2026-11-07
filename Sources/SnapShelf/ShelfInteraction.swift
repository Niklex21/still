import Foundation
import Combine

enum ShelfLayout {
    static let historyGutter: CGFloat = 28
    // Invisible clearance for the card shadows, not a visible panel backdrop.
    static func minimizedSize(recentCount: Int, hasOlder: Bool) -> CGSize {
        guard recentCount > 0 || hasOlder else { return CGSize(width: 192, height: 156) }
        let cards = CGFloat(recentCount) * 152
        let gaps = CGFloat(max(0, recentCount + (hasOlder ? 1 : 0) - 1)) * 12
        return CGSize(width: 40 + historyGutter + cards + gaps + (hasOlder ? 124 : 0), height: 156)
    }
    static func panelSize(expanded: Bool, compact: CGSize, current: CGSize, shelfCount: Int, availableWidth: CGFloat) -> CGSize {
        guard expanded else { return CGSize(width: min(compact.width, availableWidth), height: compact.height) }
        // Expansion must contain the compact footprint. Shrinking it under the
        // pointer creates synthetic exits, followed by a collapse/expand loop.
        let width = min(availableWidth, max(compact.width, current.width, min(560, max(240, 16 + CGFloat(shelfCount) * 158))))
        return CGSize(width: width, height: max(162, compact.height, current.height))
    }
}

/// Keeps pointer, scrolling, and review timing independent of thumbnail layout.
final class ShelfInteraction: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var scrolling = false
    @Published private(set) var hoveredID: UUID?
    @Published private(set) var pointerIsInside = false
    @Published private(set) var manuallyOpened = false
    @Published private(set) var dragging = false
    var onHoverChanged: (UUID?) -> Void = { _ in }
    var onExpansion: (Bool) -> Void = { _ in }
    var onViewed: (Set<UUID>) -> Void = { _ in }
    private var inside = false
    private(set) var resizing = false
    private var candidate: UUID?
    private var visible: Set<UUID> = []
    private var reviewed: Set<UUID> = []
    private var expansionTask: DispatchWorkItem?
    private var settlingTask: DispatchWorkItem?
    private var reviewTask: DispatchWorkItem?
    private let reviewDelay: TimeInterval
    private let settlingDelay: TimeInterval
    private let expansionDelay: TimeInterval
    private let collapseDelay: TimeInterval

    init(reviewDelay: TimeInterval = 0.8, settlingDelay: TimeInterval = 0.25, expansionDelay: TimeInterval = 0.06, collapseDelay: TimeInterval = 0.26) {
        self.reviewDelay = reviewDelay; self.settlingDelay = settlingDelay
        self.expansionDelay = expansionDelay; self.collapseDelay = collapseDelay
    }
    static func visibleItems(frames: [UUID: CGRect], size: CGSize) -> Set<UUID> {
        let bounds = CGRect(origin: .zero, size: size)
        return Set(frames.compactMap { id, frame -> UUID? in
            let intersection = frame.intersection(bounds)
            guard frame.width > 0, frame.height > 0, !intersection.isNull,
                  intersection.width * intersection.height >= frame.width * frame.height * 0.65 else { return nil }
            return id
        })
    }
    deinit { expansionTask?.cancel(); settlingTask?.cancel(); reviewTask?.cancel() }
    func shouldHideWhenEmpty(queueCount: Int) -> Bool { !manuallyOpened && !dragging && queueCount == 0 }
    func shouldHideWhenMinimized(pendingCount: Int) -> Bool { !manuallyOpened && !expanded && !dragging && pendingCount == 0 }
    func present(expanded: Bool, manuallyOpened: Bool = false) {
        expansionTask?.cancel(); settlingTask?.cancel(); reviewTask?.cancel()
        self.manuallyOpened = manuallyOpened
        inside = false; pointerIsInside = false; candidate = nil; visible = []; setHovered(nil); scrolling = false; dragging = false; resizing = false
        setExpanded(expanded)
    }
    func dismiss() { present(expanded: false, manuallyOpened: false) }
    func pointerInside(_ inside: Bool) {
        self.inside = inside
        if pointerIsInside != inside { pointerIsInside = inside }
        guard !resizing else { return }
        guard !inside else { return }
        expansionTask?.cancel()
        guard !manuallyOpened, !dragging else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.inside, !self.scrolling, !self.dragging else { return }
            self.setExpanded(false)
        }
        expansionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: task)
    }
    func stackHovered(_ inside: Bool, delay: TimeInterval? = nil) {
        expansionTask?.cancel()
        guard inside, !scrolling, !dragging, !resizing else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.inside, !self.scrolling, !self.dragging else { return }
            self.setExpanded(true)
        }
        expansionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? expansionDelay), execute: task)
    }
    func beginResize() {
        resizing = true
        expansionTask?.cancel()
    }
    func finishResize(pointerInside: Bool) {
        resizing = false
        self.pointerInside(pointerInside)
    }
    func beginDragging() {
        dragging = true; expansionTask?.cancel(); reviewTask?.cancel(); settlingTask?.cancel()
        candidate = nil; setHovered(nil)
    }
    func endDragging() {
        dragging = false
        if !inside { pointerInside(false) }
        scheduleReview()
        // Also reconciles the hidden state after the final successful drop.
        onExpansion(expanded)
    }
    private func setHovered(_ id: UUID?) {
        guard hoveredID != id else { return }
        hoveredID = id; onHoverChanged(id)
    }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if !value { setHovered(nil); visible = []; reviewTask?.cancel() }
        else { scheduleReview() }
        onExpansion(value)
    }
    func pointer(over id: UUID, inside: Bool) {
        if inside { candidate = id }
        else if candidate == id { candidate = nil }
        if !scrolling && !dragging { setHovered(candidate) }
    }
    func visibleItems(_ ids: Set<UUID>) {
        guard visible != ids else { return }
        visible = ids
        scheduleReview()
    }
    func scrolled() {
        expansionTask?.cancel()
        settlingTask?.cancel()
        reviewTask?.cancel()
        scrolling = true
        setHovered(nil)
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrolling = false
            self.setHovered(self.candidate.flatMap { !self.expanded || self.visible.contains($0) ? $0 : nil })
            self.scheduleReview()
            if !self.inside { self.pointerInside(false) }
        }
        settlingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + settlingDelay, execute: task)
    }
    private func scheduleReview() {
        reviewTask?.cancel()
        guard expanded, !scrolling, !dragging else { return }
        let pending = visible.subtracting(reviewed)
        guard !pending.isEmpty else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, !self.scrolling, !self.dragging else { return }
            let seen = pending.intersection(self.visible)
            self.reviewed.formUnion(seen)
            if !seen.isEmpty { self.onViewed(seen) }
        }
        reviewTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + reviewDelay, execute: task)
    }
}
