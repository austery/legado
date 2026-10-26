import SwiftUI
import UIKit

struct ReadingStyle: Equatable, Codable {
    var fontName = "PingFangSC-Regular"
    var size: Double = 22
    var lineSpacing: Double = 6
    var paragraphSpacing: Double = 12
    var margin: Double = 28
    var dark = false
}

/// Identity is the stable engine reading token, not a changing saved-position revision.
struct ReadingRestoration: Equatable {
    let identity: String
    let utf16Offset: Int
}

final class AnchoredTextView: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var anchor = 0
    private var readingIsActive = true
    var restoring = false
    var chapterKey = ""
    var style = ReadingStyle()
    private var previousSize = CGSize.zero
    private(set) var spreadView: ReadingSpreadView?
    private var spreadNeedsReflow = true
    var usesSpreads: Bool { spreadView?.isHidden == false }
    private var needsAnchorRestoration = true
    private var restoration: ReadingRestoration?
    private var validRestoration = true
    private var displayedIdentity: String?
    private var displayScheduled = false
    private var renderGeneration = 0
    private var userScrolling = false
    private var findPresentation: ChapterFindPresentation?
    private var lastFindRequest: UUID?
    private var findHighlightGeneration = -1
    private var findRevealOffset: Int?
    private var preservingFindAnchor = false
    private var onDisplayed: ((String, Int) -> Void)?
    private var onParagraphScroll: ((String, Int) -> Void)?

    var onToggleControls: (() -> Void)?
    private var controlsTouchStarted: TimeInterval = 0
    private var controlsTouchHadSelection = false
    private weak var controlsTouchPage: UITextView?

    private lazy var controlsTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    func enableControlsTap() {
        addGestureRecognizer(controlsTap)
        controlsTap.require(toFail: panGestureRecognizer)
    }

    @objc private func toggleControls() {
        // Simultaneous native selection can finish on the same touch-up. A held
        // touch belongs to selection even if its selected range is delivered later.
        guard readingIsActive,
              ProcessInfo.processInfo.systemUptime - controlsTouchStarted < 0.5 else { return }
        if controlsTouchHadSelection {
            // Separate page views do not dismiss another page's selection themselves.
            // Coordinate only a short tap on another page. Same-page selection/menu
            // interactions, drags and held selections remain entirely native.
            for page in visibleTextViews where page !== controlsTouchPage && page.selectedRange.length > 0 {
                page.selectedTextRange = nil
                page.resignFirstResponder()
            }
            return
        }
        guard !hasVisibleSelection else { return }
        onToggleControls?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === controlsTap else { return true }
        guard readingIsActive else { return false }
        controlsTouchStarted = touch.timestamp
        let center = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.20)
        guard center.contains(touch.location(in: self)) else { return false }
        // Remember before UIKit may dismiss the selection on touch-up.
        controlsTouchHadSelection = hasVisibleSelection
        controlsTouchPage = visibleTextViews.first { page in
            touch.view?.isDescendant(of: page) == true
        }
        return true
    }

    private var visibleTextViews: [UITextView] {
        if let spreads = spreadView, usesSpreads {
            return spreads.subviews.compactMap { $0 as? UITextView }.filter {
                $0.frame.intersects(spreads.bounds)
            }
        }
        return [self]
    }

    private var hasVisibleSelection: Bool {
        visibleTextViews.contains { $0.selectedRange.length > 0 }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Spread pages own native selection recognizers. Observe a completed tap
        // without preventing selection; the pan failure requirements still apply.
        gestureRecognizer === controlsTap || otherGestureRecognizer === controlsTap
    }

    /// Matches NativeBodyCoordinates without normalizing or replacing the original body.
    private func paragraphStart(_ offset: Int) -> Int? {
        let body = text as NSString
        guard offset >= 0, offset <= body.length else { return nil }
        if offset > 0, offset < body.length,
           (0xD800...0xDBFF).contains(body.character(at: offset - 1)),
           (0xDC00...0xDFFF).contains(body.character(at: offset)) { return nil }
        var start = 0
        var cursor = 0
        while cursor < offset {
            let character = body.character(at: cursor)
            let end: Int
            switch character {
            case 13: end = cursor + ((cursor + 1 < body.length && body.character(at: cursor + 1) == 10) ? 2 : 1)
            case 10, 0x2028, 0x2029: end = cursor + 1
            default: cursor += 1; continue
            }
            if end <= offset { start = end }
            cursor = end
        }
        return start
    }

    func configure(chapterKey: String, body: String, style: ReadingStyle,
                   restoration: ReadingRestoration?, onDisplayed: ((String, Int) -> Void)?,
                   onParagraphScroll: ((String, Int) -> Void)?, isReading: Bool = true) {
        // Navigation changes the view size before its opacity necessarily changes.
        // Preserve the session anchor through those non-reading layout callbacks.
        if readingIsActive != isReading {
            readingIsActive = isReading
            userScrolling = false
            needsAnchorRestoration = true
            setNeedsLayout()
        }
        self.onDisplayed = onDisplayed
        self.onParagraphScroll = onParagraphScroll
        let newChapter = self.chapterKey != chapterKey
        let newIdentity = self.restoration?.identity != restoration?.identity
        let newBody = !text.utf16.elementsEqual(body.utf16)
        let newStyle = self.style != style
        // Keep the original restoration offset for this token even if SwiftUI supplies a later sample.
        if newIdentity || newChapter { self.restoration = restoration }
        guard newChapter || newIdentity || newBody || newStyle else {
            scheduleDisplayed()
            return
        }
        restoring = true
        defer { restoring = false }
        renderGeneration += 1
        displayScheduled = false
        userScrolling = false
        self.chapterKey = chapterKey
        self.style = style
        if newChapter || newIdentity || newBody {
            displayedIdentity = nil
            findPresentation = nil
            findRevealOffset = nil
            preservingFindAnchor = false
            lastFindRequest = nil
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        let color: UIColor = style.dark ? .init(white: 0.88, alpha: 1) : .init(white: 0.12, alpha: 1)
        attributedText = NSAttributedString(string: body, attributes: [
            .font: UIFont(name: style.fontName, size: style.size) ?? UIFont.systemFont(ofSize: style.size),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
        backgroundColor = style.dark ? UIColor(white: 0.08, alpha: 1) : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        if newChapter || newIdentity || newBody {
            let requested = self.restoration?.utf16Offset ?? (newChapter ? 0 : anchor)
            let normalized = paragraphStart(requested)
            validRestoration = normalized != nil
            anchor = normalized ?? 0
        }
        spreadNeedsReflow = true
        needsAnchorRestoration = true
        setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolling = true
        preservingFindAnchor = false
        findRevealOffset = nil
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userScrolling = false }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userScrolling = false }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !usesSpreads, readingIsActive, !restoring, !needsAnchorRestoration, !text.isEmpty,
              !preservingFindAnchor || userScrolling else { return }
        let point = CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + textContainerInset.top + 1)
        guard let position = closestPosition(to: point),
              let normalized = paragraphStart(offset(from: beginningOfDocument, to: position)) else { return }
        anchor = normalized
        guard userScrolling, bodyIsVisible, let identity = restoration?.identity,
              displayedIdentity == identity, validRestoration else { return }
        onParagraphScroll?(identity, anchor)
    }

    func restoreAnchor() {
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        let wasRestoring = restoring
        restoring = true
        defer { restoring = wasRestoring }
        let displayOffset = findRevealOffset ?? anchor
        if usesSpreads {
            spreadView?.restore(anchor: displayOffset)
            needsAnchorRestoration = false
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        if let position = position(from: beginningOfDocument, offset: displayOffset) {
            // caretRect also represents the empty last paragraph after a trailing delimiter.
            let rect = caretRect(for: position)
            let maximum = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let top = findRevealOffset == nil ? textContainerInset.top : max(96, textContainerInset.top)
            let target = max(-adjustedContentInset.top, rect.minY - top)
            setContentOffset(CGPoint(x: 0, y: min(maximum, target)), animated: false)
        }
        needsAnchorRestoration = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    // UIKit can adjust contentOffset during a size change before layoutSubviews.
    // Keep the accepted text anchor until that new layout has restored it.
    override var bounds: CGRect {
        willSet { if newValue.size != bounds.size { needsAnchorRestoration = true } }
    }

    override var frame: CGRect {
        willSet { if newValue.size != frame.size { needsAnchorRestoration = true } }
    }

    override func layoutSubviews() {
        let wasRestoring = restoring
        restoring = true
        let changed = previousSize != bounds.size
        let inset = max(style.margin, (bounds.width - 680) / 2)
        let desiredInset = UIEdgeInsets(top: 24, left: inset, bottom: 40, right: inset)
        if textContainerInset != desiredInset { textContainerInset = desiredInset }
        let landscape = window.map { $0.bounds.width > $0.bounds.height } ?? false
        let wantsSpreads = traitCollection.userInterfaceIdiom == .pad && landscape && bounds.width >= 900 && bounds.height >= 160
        let modeChanged = wantsSpreads != usesSpreads
        if wantsSpreads, spreadView == nil {
            let pages = ReadingSpreadView()
            pages.updateFindHighlights(matches: findPresentation?.matches ?? [], selected: findPresentation?.selectedRange)
            pages.onTurn = { [weak self] offset in self?.acceptPageTurn(offset) }
            controlsTap.require(toFail: pages.panGestureRecognizer)
            spreadView = pages
            addSubview(pages)
        }
        spreadView?.isHidden = !wantsSpreads
        // Disabling UITextView scrolling changes its intrinsic height to the entire
        // chapter under SwiftUI. Keep its viewport sizing and disable only its gesture.
        panGestureRecognizer.isEnabled = !wantsSpreads
        showsVerticalScrollIndicator = !wantsSpreads
        super.layoutSubviews()
        if wantsSpreads, let pages = spreadView {
            setContentOffset(.zero, animated: false)
            pages.frame = CGRect(origin: .zero, size: bounds.size)
            bringSubviewToFront(pages)
            if changed || modeChanged || spreadNeedsReflow {
                pages.reflow(text: attributedText, margin: style.margin, anchor: anchor,
                             paper: backgroundColor ?? .systemBackground)
                spreadNeedsReflow = false
            }
        }
        if changed || modeChanged || needsAnchorRestoration { restoreAnchor() }
        previousSize = bounds.size
        restoring = wasRestoring
        scheduleDisplayed()
        applyFindNavigation()
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if usesSpreads { return spreadView?.accessibilityScroll(direction) ?? false }
        preservingFindAnchor = false
        findRevealOffset = nil
        return super.accessibilityScroll(direction)
    }

    private func acceptPageTurn(_ offset: Int) {
        guard readingIsActive, !restoring, !needsAnchorRestoration, bodyIsVisible,
              let normalized = paragraphStart(offset) else { return }
        findRevealOffset = nil
        preservingFindAnchor = false
        anchor = normalized
        guard let identity = restoration?.identity, displayedIdentity == identity, validRestoration else { return }
        onParagraphScroll?(identity, anchor)
    }

    func applyFind(_ candidate: ChapterFindPresentation?) {
        let valid = candidate.flatMap { presentation -> ChapterFindPresentation? in
            guard readingIsActive, presentation.context.matches(chapterKey: chapterKey,
                      readingIdentity: restoration?.identity, text: text),
                  presentation.matches.allSatisfy(validFindRange),
                  presentation.selectedRange.map(validFindRange) ?? true,
                  presentation.request.map({ validFindRange($0.range) }) ?? true else { return nil }
            return presentation
        }
        if findPresentation != valid || findHighlightGeneration != renderGeneration {
            if findPresentation != nil || valid != nil { preservingFindAnchor = true }
            if findPresentation?.selectedRange != valid?.selectedRange { findRevealOffset = nil }
            findPresentation = valid
            findHighlightGeneration = renderGeneration
            let wasRestoring = restoring
            restoring = true
            updateFindHighlights(matches: valid?.matches ?? [], selected: valid?.selectedRange,
                                 originalRange: NSRange(location: 0, length: textStorage.length))
            spreadView?.updateFindHighlights(matches: valid?.matches ?? [], selected: valid?.selectedRange)
            restoring = wasRestoring
            setNeedsLayout()
        }
        applyFindNavigation()
    }

    private func validFindRange(_ range: NSRange) -> Bool {
        let body = text as NSString
        guard range.location >= 0, range.length > 0, range.length <= body.length,
              range.location <= body.length - range.length else { return false }
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < body.length && (0xD800...0xDBFF).contains(body.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(body.character(at: offset))
        }
        return !splitsSurrogate(range.location) && !splitsSurrogate(NSMaxRange(range))
    }

    private func applyFindNavigation() {
        guard let findPresentation, let request = findPresentation.request,
              lastFindRequest != request.id, readingIsActive, bodyIsVisible,
              !restoring, !needsAnchorRestoration,
              findPresentation.context.matches(chapterKey: chapterKey,
                  readingIdentity: restoration?.identity, text: text),
              let offset = paragraphStart(request.range.location) else { return }
        lastFindRequest = request.id
        anchor = offset
        findRevealOffset = request.range.location
        preservingFindAnchor = true
        restoreAnchor()
        let identity = findPresentation.context.readingIdentity
        let generation = renderGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readingIsActive, self.bodyIsVisible,
                  self.renderGeneration == generation, self.validRestoration,
                  self.restoration?.identity == identity, self.displayedIdentity == identity,
                  self.findPresentation?.request?.id == request.id else { return }
            self.onParagraphScroll?(identity, offset)
        }
    }

    private var bodyIsVisible: Bool {
        guard let window, !window.isHidden, bounds.width > 0, bounds.height > 0,
              convert(bounds, to: window).intersects(window.bounds) else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0 || view.layer.opacity <= 0 { return false }
            ancestor = view.superview
        }
        return true
    }

    private func scheduleDisplayed() {
        guard !restoring, !needsAnchorRestoration, validRestoration,
              bodyIsVisible,
              let identity = restoration?.identity, displayedIdentity != identity,
              onDisplayed != nil, !displayScheduled else { return }
        let generation = renderGeneration
        let restoredOffset = anchor
        displayScheduled = true
        // Publishing during SwiftUI update/layout is unsafe; verify the token again at delivery.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderGeneration == generation else { return }
            self.displayScheduled = false
            guard self.restoration?.identity == identity, self.displayedIdentity != identity,
                  self.bodyIsVisible,
                  !self.restoring, !self.needsAnchorRestoration, self.validRestoration,
                  let callback = self.onDisplayed else { return }
            self.displayedIdentity = identity
            callback(identity, restoredOffset)
        }
    }
}

struct ReadingText: UIViewRepresentable {
    let chapterKey: String
    let text: String
    let style: ReadingStyle
    var restoration: ReadingRestoration? = nil
    var onDisplayed: ((String, Int) -> Void)? = nil
    var onParagraphScroll: ((String, Int) -> Void)? = nil
    var isReading = true
    var onToggleControls: (() -> Void)? = nil
    var find: ChapterFindPresentation? = nil

    // Fill the proposed viewport without measuring the chapter text during layout.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnchoredTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeUIView(context: Context) -> AnchoredTextView {
        let view = AnchoredTextView()
        view.delegate = view
        view.enableControlsTap()
        view.isEditable = false
        view.isSelectable = true
        // Keep fast drags inside the chapter instead of exposing an empty overscroll viewport.
        view.bounces = false
        view.accessibilityIdentifier = "reader.text"
        return view
    }

    func updateUIView(_ view: AnchoredTextView, context: Context) {
        view.onToggleControls = onToggleControls
        view.configure(chapterKey: chapterKey, body: text, style: style, restoration: restoration,
                       onDisplayed: onDisplayed, onParagraphScroll: onParagraphScroll, isReading: isReading)
        view.applyFind(find)
    }
}
