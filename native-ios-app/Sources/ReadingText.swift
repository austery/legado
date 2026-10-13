import SwiftUI
import UIKit

struct ReadingStyle: Equatable {
    var fontName = "PingFangSC-Regular"
    var size: Double = 22
    var lineSpacing: Double = 6
    var paragraphSpacing: Double = 12
    var margin: Double = 24
    var dark = false
}

final class AnchoredTextView: UITextView, UITextViewDelegate {
    var anchor = 0
    var restoring = false
    var previousWidth: CGFloat = 0
    var chapterKey = ""
    var style = ReadingStyle()

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring, !text.isEmpty else { return }
        let point = CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + textContainerInset.top + 1)
        if let position = closestPosition(to: point) {
            let offset = offset(from: beginningOfDocument, to: position)
            anchor = (text as NSString).paragraphRange(for: NSRange(location: min(offset, (text as NSString).length), length: 0)).location
        }
    }

    func restoreAnchor() {
        guard !text.isEmpty else { return }
        restoring = true
        layoutManager.ensureLayout(for: textContainer)
        let location = min(anchor, max(0, (text as NSString).length - 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let maximum = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: min(maximum, max(-adjustedContentInset.top, rect.minY))), animated: false)
        restoring = false
    }

    override func layoutSubviews() {
        let changed = previousWidth != bounds.width
        if changed {
            restoring = true
            let inset = max(style.margin, (bounds.width - 760) / 2)
            textContainerInset = UIEdgeInsets(top: 24, left: inset, bottom: 40, right: inset)
        }
        super.layoutSubviews()
        if changed { previousWidth = bounds.width; restoreAnchor(); restoring = false }
    }
}

struct ReadingText: UIViewRepresentable {
    let chapterKey: String
    let text: String
    let style: ReadingStyle

    func makeUIView(context: Context) -> AnchoredTextView {
        let view = AnchoredTextView()
        view.delegate = view
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "reader.text"
        return view
    }

    func updateUIView(_ view: AnchoredTextView, context: Context) {
        let newChapter = view.chapterKey != chapterKey
        guard newChapter || view.style != style || view.text != text else { return }
        let savedAnchor = newChapter ? 0 : view.anchor
        view.restoring = true
        view.chapterKey = chapterKey
        view.style = style
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        let color: UIColor = style.dark ? .init(white: 0.88, alpha: 1) : .init(white: 0.12, alpha: 1)
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont(name: style.fontName, size: style.size) ?? UIFont.systemFont(ofSize: style.size),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
        view.backgroundColor = style.dark ? UIColor(white: 0.08, alpha: 1) : UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        let inset = max(style.margin, (view.bounds.width - 760) / 2)
        view.textContainerInset = UIEdgeInsets(top: 24, left: inset, bottom: 40, right: inset)
        view.anchor = savedAnchor
        view.restoreAnchor()
        view.restoring = false
    }
}
