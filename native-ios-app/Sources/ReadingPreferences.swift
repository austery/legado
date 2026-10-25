import SwiftUI
import UIKit

enum ShelfLayout: String, CaseIterable {
    case grid, list
}

/// Presentation preferences belong to this app, independently of book progress.
@MainActor
final class ReadingPreferences: ObservableObject {
    static let shared = ReadingPreferences()
    static let storageKey = "nativeReader.readingStyle.v1"
    private let defaults: UserDefaults
    static let prefetchKey = "nativeReader.prefetchNextTwo.v1"
    static let shelfLayoutKey = "nativeReader.shelfLayout.v1"
    @Published var shelfLayout: ShelfLayout {
        didSet { defaults.set(shelfLayout.rawValue, forKey: Self.shelfLayoutKey) }
    }
    @Published var prefetchNextTwo: Bool {
        didSet { defaults.set(prefetchNextTwo, forKey: Self.prefetchKey) }
    }

    @Published var style: ReadingStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) {
                defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shelfLayout = defaults.string(forKey: Self.shelfLayoutKey).flatMap(ShelfLayout.init(rawValue:)) ?? .grid
        prefetchNextTwo = defaults.bool(forKey: Self.prefetchKey)
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(ReadingStyle.self, from: $0) }
        var value = saved ?? ReadingStyle()
        let initial = ReadingStyle()
        func valid(_ number: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
            number.isFinite && range.contains(number) ? number : fallback
        }
        value.size = valid(value.size, in: 16...36, fallback: initial.size)
        value.lineSpacing = valid(value.lineSpacing, in: 0...18, fallback: initial.lineSpacing)
        value.paragraphSpacing = valid(value.paragraphSpacing, in: 0...30, fallback: initial.paragraphSpacing)
        value.margin = valid(value.margin, in: 12...64, fallback: initial.margin)
        if UIFont(name: value.fontName, size: value.size) == nil { value.fontName = initial.fontName }
        style = value
    }
}
