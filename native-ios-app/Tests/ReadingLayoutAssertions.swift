import UIKit
@testable import NativeReader

/// Observe the actual attached text views, independently of cached pagination ranges.
@MainActor
func renderedSpreadRanges(in view: AnchoredTextView) -> [NSRange] {
    guard view.usesSpreads, let spreads = view.spreadView else { return [] }
    return spreads.subviews.compactMap { $0 as? UITextView }.filter {
        !$0.isHidden && $0.frame.intersects(spreads.bounds)
    }.map { page in
        let glyphs = page.layoutManager.glyphRange(forBoundingRect: page.bounds, in: page.textContainer)
        let local = page.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return NSRange(location: local.location + ((page as? ReadingPageTextView)?.originalRange.location ?? 0), length: local.length)
    }
}
