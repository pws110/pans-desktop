import AppKit

// Finder receives the actual URL and a move-only operation mask, rather than a
// promise that creates a copy. Our private payload takes priority between zones.
final class FileMoveItem: NSObject, NSPasteboardWriting {
    let source: URL
    let tracking: TrackedReference
    let referenceData: Data
    static let referenceType = NSPasteboard.PasteboardType("com.andy.clearzones.reference")
    init(source: URL, referenceData: Data) throws {
        guard StorageEngine.movableItem(source) else { throw StorageError.unsupported }
        self.source = source; self.referenceData = referenceData
        tracking = try TrackedReference(url: source)
    }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [Self.referenceType, .fileURL] }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.referenceType { return referenceData }
        if type == .fileURL { return source.absoluteString }
        return nil
    }
}
