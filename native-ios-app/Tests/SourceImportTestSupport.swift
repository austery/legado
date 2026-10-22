import Foundation
@testable import NativeReader

@MainActor
extension ReaderModel {
    /// Existing journeys explicitly accept fixture replacements through the new review step.
    func confirmFixtureImport() {
        sourceImportSelection = Set(sourceImportPreview?.items.map { $0.source.id } ?? [])
        importKeepName = false
        importKeepGroups = false
        importKeepEnabled = false
        confirmSourceImport()
    }
}
