import UIKit

/// Disposable TextKit layout. Ranges address the original chapter, never a second body.
@MainActor
final class ReadingPagination {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    private(set) var ranges: [NSRange] = []

    init(text: NSAttributedString, pageSize: CGSize) {
        storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(manager)
        manager.allowsNonContiguousLayout = false
        var end = 0
        repeat {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            ranges.append(range)
            let next = NSMaxRange(range)
            // A valid reader viewport fits at least one line at the largest supported size.
            guard next > end else { break }
            end = next
        } while end < storage.length
    }

    func page(containing offset: Int) -> Int {
        ranges.firstIndex { NSLocationInRange(offset, $0) } ?? max(0, ranges.count - 1)
    }
}

/// Original-text pagination is independent of selectable, disposable page views.
/// Only the visible spread and its neighbors own text views; chapter layout is in memory.
@MainActor
final class ReadingSpreadView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private(set) var pagination: ReadingPagination?
    private(set) var spread = 0
    private var pages: [Int: UITextView] = [:]
    private var pageSize = CGSize.zero
    private let verticalPageInset: CGFloat = 12
    private var margin: CGFloat = 28
    private var reflowing = false
    private var dragStartSpread: Int?
    private var touchStartedAtEnd = false
    private var findMatches: [NSRange] = []
    private var selectedFindRange: NSRange?
    var onTurn: ((Int) -> Void)?
    var onForwardAtEnd: (() -> Void)? {
        didSet { if onForwardAtEnd == nil { touchStartedAtEnd = false } }
    }
    private lazy var endSwipe: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(finishEndSwipe(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    var firstVisibleOffset: Int { pagination?.ranges[spread * 2].location ?? 0 }
    var visibleRanges: [NSRange] {
        guard let pagination else { return [] }
        return Array(pagination.ranges.dropFirst(spread * 2).prefix(2))
    }
    private var atFinalSpread: Bool {
        guard let pagination else { return false }
        return spread == (pagination.ranges.count - 1) / 2 && abs(contentOffset.x - CGFloat(spread) * bounds.width) < 1
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        isPagingEnabled = true
        bounces = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "reader.spreads"
        // The stock scroll pan may not drag at all when the chapter fits on one spread.
        addGestureRecognizer(endSwipe)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reflow(text: NSAttributedString, margin: CGFloat, anchor: Int, paper: UIColor) {
        reflowing = true
        defer { reflowing = false }
        pages.values.forEach { $0.removeFromSuperview() }
        pages.removeAll()
        self.margin = margin
        backgroundColor = paper
        pageSize = CGSize(width: (bounds.width - 2 * margin - 40) / 2,
                          height: bounds.height - 2 * verticalPageInset)
        pagination = ReadingPagination(text: text, pageSize: pageSize)
        let count = max(1, ((pagination?.ranges.count ?? 0) + 1) / 2)
        contentSize = CGSize(width: CGFloat(count) * bounds.width, height: bounds.height)
        restore(anchor: anchor)
    }

    func restore(anchor: Int) {
        reflowing = true
        defer { reflowing = false }
        dragStartSpread = nil
        touchStartedAtEnd = false
        spread = (pagination?.page(containing: anchor) ?? 0) / 2
        setContentOffset(CGPoint(x: CGFloat(spread) * bounds.width, y: 0), animated: false)
        renderNeighbors()
    }

    func updateFindHighlights(matches: [NSRange], selected: NSRange?) {
        findMatches = matches
        selectedFindRange = selected
        for page in pages.values {
            guard let page = page as? ReadingPageTextView else { continue }
            page.updateFindHighlights(matches: matches, selected: selected, originalRange: page.originalRange)
        }
    }

    private func renderNeighbors() {
        guard let pagination else { return }
        let wanted = Set(max(0, (spread - 1) * 2)..<min(pagination.ranges.count, (spread + 2) * 2))
        for index in Array(pages.keys) where !wanted.contains(index) {
            pages.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in wanted.sorted() {
            let view: UITextView
            if let existing = pages[index] { view = existing }
            else {
                let range = pagination.ranges[index]
                view = ReadingPageTextView(originalRange: range,
                                           text: pagination.storage.attributedSubstring(from: range))
                view.isEditable = false
                view.isSelectable = true
                view.isScrollEnabled = false
                view.textContainerInset = .zero
                view.textContainer.widthTracksTextView = false
                view.textContainer.heightTracksTextView = false
                view.backgroundColor = backgroundColor
                view.accessibilityIdentifier = index % 2 == 0 ? "reader.page.left" : "reader.page.right"
                pages[index] = view
                addSubview(view)
            }
            if let page = view as? ReadingPageTextView {
                page.updateFindHighlights(matches: findMatches, selected: selectedFindRange, originalRange: page.originalRange)
            }
            view.textContainer.size = pageSize
            view.frame = CGRect(x: CGFloat(index / 2) * bounds.width + margin + CGFloat(index % 2) * (pageSize.width + 40),
                                y: verticalPageInset, width: pageSize.width, height: pageSize.height)
            view.accessibilityElementsHidden = index / 2 != spread
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { dragStartSpread = spread }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !reflowing, bounds.width > 0, let pagination else { return }
        spread = min(max(0, Int((contentOffset.x / bounds.width).rounded())), (pagination.ranges.count - 1) / 2)
        renderNeighbors()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishTurn() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishTurn() }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let pagination else { return false }
        let delta: Int
        switch direction {
        case .left, .next: delta = 1
        case .right, .previous: delta = -1
        default: return false
        }
        let target = spread + delta
        guard target >= 0, target < (pagination.ranges.count + 1) / 2 else { return false }
        dragStartSpread = spread
        setContentOffset(CGPoint(x: CGFloat(target) * bounds.width, y: 0), animated: false)
        scrollViewDidScroll(self)
        finishTurn()
        UIAccessibility.post(notification: .pageScrolled,
                             argument: "Page \(target * 2 + 1) of \(pagination.ranges.count)")
        return true
    }

    private func finishTurn() {
        guard let start = dragStartSpread, !reflowing else { return }
        dragStartSpread = nil
        guard start != spread else { return }
        onTurn?(firstVisibleOffset)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === endSwipe else { return true }
        touchStartedAtEnd = onForwardAtEnd != nil && atFinalSpread && !reflowing && !isDragging && !isDecelerating &&
            !(spread * 2...spread * 2 + 1).contains { (pages[$0]?.selectedRange.length ?? 0) > 0 }
        return touchStartedAtEnd
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === endSwipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = endSwipe.velocity(in: self)
        return touchStartedAtEnd && -velocity.x > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === endSwipe && otherGestureRecognizer === panGestureRecognizer
    }

    @objc private func finishEndSwipe(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .cancelled { touchStartedAtEnd = false }
        guard gesture.state == .ended, touchStartedAtEnd else { return }
        touchStartedAtEnd = false
        let movement = gesture.translation(in: self)
        guard atFinalSpread, -movement.x >= bounds.width * 0.08, -movement.x > abs(movement.y) else { return }
        onForwardAtEnd?()
    }
}

/// A single-container view retains UIKit selection; multi-container views disable it.
/// This disposable page copy never becomes an engine body or a saved position.
final class ReadingPageTextView: UITextView {
    let originalRange: NSRange

    init(originalRange: NSRange, text: NSAttributedString) {
        self.originalRange = originalRange
        super.init(frame: .zero, textContainer: nil)
        attributedText = text
        textContainer.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
