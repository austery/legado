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

final class AnchoredTextView: UITextView, UITextViewDelegate {
    var anchor = 0
    private var readingIsActive = true
    var restoring = false
    var chapterKey = ""
    var style = ReadingStyle()
    private var previousSize = CGSize.zero
    private var needsAnchorRestoration = true
    private var restoration: ReadingRestoration?
    private var validRestoration = true
    private var displayedIdentity: String?
    private var displayScheduled = false
    private var renderGeneration = 0
    private var userScrolling = false
    private var onDisplayed: ((String, Int) -> Void)?
    private var onParagraphScroll: ((String, Int) -> Void)?

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
        let newBody = text != body
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
        if newChapter || newIdentity || newBody { displayedIdentity = nil }
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
        needsAnchorRestoration = true
        setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolling = true }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userScrolling = false }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userScrolling = false }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard readingIsActive, !restoring, !needsAnchorRestoration, !text.isEmpty else { return }
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
        layoutManager.ensureLayout(for: textContainer)
        if let position = position(from: beginningOfDocument, offset: anchor) {
            // caretRect also represents the empty last paragraph after a trailing delimiter.
            let rect = caretRect(for: position)
            let maximum = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let target = max(-adjustedContentInset.top, rect.minY - textContainerInset.top)
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
        super.layoutSubviews()
        if changed || needsAnchorRestoration { restoreAnchor() }
        previousSize = bounds.size
        restoring = wasRestoring
        scheduleDisplayed()
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

    func makeUIView(context: Context) -> AnchoredTextView {
        let view = AnchoredTextView()
        view.delegate = view
        view.isEditable = false
        view.isSelectable = true
        // Keep fast drags inside the chapter instead of exposing an empty overscroll viewport.
        view.bounces = false
        view.accessibilityIdentifier = "reader.text"
        return view
    }

    func updateUIView(_ view: AnchoredTextView, context: Context) {
        view.configure(chapterKey: chapterKey, body: text, style: style, restoration: restoration,
                       onDisplayed: onDisplayed, onParagraphScroll: onParagraphScroll, isReading: isReading)
    }
}
