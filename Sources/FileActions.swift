import AppKit

enum FileActionError: LocalizedError {
    case invalidName, outputUnavailable, compressionFailed
    var errorDescription: String? {
        switch self {
        case .invalidName: return L("名称不能为空，也不能包含斜杠或冒号。", "Enter a name without slashes or colons.")
        case .outputUnavailable: return L("目标位置不可用，未覆盖现有文件。", "The destination is unavailable. No existing files were overwritten.")
        case .compressionFailed: return L("压缩未完成，原文件保持不动。", "Compression did not complete. Original files are unchanged.")
        }
    }
}

struct TileClickTracker {
    private var previous: (key: String, time: TimeInterval, point: CGPoint)?
    mutating func cancel() { previous = nil }
    mutating func released(key: String, time: TimeInterval, point: CGPoint, systemClicks: Int,
                           modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { cancel(); return false }
        let twice = previous.map { $0.key == key && time >= $0.time && time - $0.time <= max(0.65, NSEvent.doubleClickInterval)
            && hypot(point.x - $0.point.x, point.y - $0.point.y) <= 20 } ?? false
        if twice { cancel(); return true }
        previous = (key, time, point); return false
    }
}

enum DesktopRevealPolicy {
    static func shouldHide(bundle: String?, regular: Bool, ownPID: pid_t, pid: pid_t, hidden: Bool) -> Bool {
        regular && ownPID != pid && !hidden
    }
}

// Keep only applications hidden by this interaction. Hiding/unhiding leaves
// their documents, window bounds and minimized windows owned by those apps.
protocol DesktopVisibilityApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isHidden: Bool { get }
    var isTerminated: Bool { get }
    func hide() -> Bool
    func unhide() -> Bool
}
extension NSRunningApplication: DesktopVisibilityApplication {}

final class DesktopVisibilitySession {
    private(set) var applications: [DesktopVisibilityApplication]? = nil
    private var awaitingRestoreConfirmation = false
    var isActive: Bool { applications != nil }
    @discardableResult func hide(_ candidates: [DesktopVisibilityApplication]) -> Int {
        if applications == nil { applications = [] }
        awaitingRestoreConfirmation = false
        // Capture the whole visible set before making any hide request. AppKit
        // may update another application's hidden state asynchronously.
        let visible = candidates.filter { !$0.isTerminated && !$0.isHidden }
        for application in visible {
            if !applications!.contains(where: { $0.processIdentifier == application.processIdentifier }) { applications!.append(application) }
        }
        var hidden = 0
        for application in visible {
            if application.hide() { hidden += 1 }
        }
        return hidden
    }
    @discardableResult func restore() -> Int {
        guard let saved = applications else { return 0 }
        applications = nil
        var restored = 0
        var failed: [DesktopVisibilityApplication] = []
        for application in saved.reversed() where !application.isTerminated && application.isHidden {
            if application.unhide() { restored += 1 }
            else { failed.insert(application, at: 0) }
        }
        if !failed.isEmpty { applications = failed; awaitingRestoreConfirmation = true }
        return restored
    }
    func confirmRestoration() {
        guard awaitingRestoreConfirmation else { return }
        applications = applications?.filter { !$0.isTerminated && $0.isHidden }
        if applications?.isEmpty == true { applications = nil; awaitingRestoreConfirmation = false }
    }
}

// All actions resolve the selected partition at action time, independently of
// other partitions. New output is staged and atomically committed without overwrite.
final class FileActionEngine {
    let store: ReferenceStore
    let storage: StorageEngine
    init(store: ReferenceStore, storage: StorageEngine) { self.store = store; self.storage = storage }
    func urls(_ paths: [String], in zone: UUID, unlocked: Bool = true) throws -> [URL] {
        guard let z = store.zones.first(where: { $0.id == zone }) else { throw StoreFailure.unavailableReference }
        guard !unlocked || !z.locked else { throw StoreFailure.lockedZone }
        return try paths.map { path in
            guard z.paths.contains(path), let url = store.resolvedURL(path, in: zone) else { throw StoreFailure.unavailableReference }
            return url
        }
    }
    static func available(_ parent: URL, stem: String, ext: String = "") -> URL {
        for index in 1...10000 {
            let suffix = index == 1 ? "" : " \(index)"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let url = parent.appendingPathComponent(name)
            if !StorageEngine.exists(url.path) { return url }
        }
        return parent.appendingPathComponent(stem + "-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }
    static func name(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != ".", n != "..", !n.contains("/"), !n.contains(":"), !n.contains("\0") else { throw FileActionError.invalidName }
        return n
    }
    static func copy(_ source: URL, to destination: URL) throws {
        guard StorageEngine.movableItem(source), !StorageEngine.exists(destination.path),
              destination.deletingLastPathComponent().path != source.path,
              !destination.path.hasPrefix(source.path + "/") else { throw FileActionError.outputUnavailable }
        let identity = try FileIdentity(url: source)
        let before = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".pans-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = stage.appendingPathComponent("output")
        try FileManager.default.copyItem(at: source, to: output)
        let after = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard try FileIdentity(url: source) == identity, before.contentModificationDate == after.contentModificationDate,
              before.fileSize == after.fileSize else { throw CopyExportError.changed }
        try StorageEngine.atomicMove(output, destination)
    }
    @discardableResult func duplicate(_ paths: [String], in zone: UUID) throws -> [URL] {
        let sources = try urls(paths, in: zone)
        var result: [URL] = []
        for source in sources {
            try storage.validateImport(source)
            let folder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let ext = folder ? "" : source.pathExtension
            let stem = (ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent) + L(" 副本", " copy")
            let target = Self.available(source.deletingLastPathComponent(), stem: stem, ext: ext)
            try Self.copy(source, to: target); result.append(target)
        }
        try store.add(result, to: zone)
        return result
    }
    @discardableResult func alias(_ paths: [String], in zone: UUID) throws -> [URL] {
        let sources = try urls(paths, in: zone); var result: [URL] = []
        for source in sources {
            try storage.validateImport(source)
            let target = Self.available(source.deletingLastPathComponent(), stem: source.lastPathComponent + L(" 替身", " alias"), ext: "alias")
            let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            let stage = target.deletingLastPathComponent().appendingPathComponent(".pans-alias-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            let output = stage.appendingPathComponent("output.alias")
            try URL.writeBookmarkData(bookmark, to: output)
            try StorageEngine.atomicMove(output, target)
            result.append(target)
        }
        try store.add(result, to: zone)
        return result
    }
    @discardableResult func compress(_ paths: [String], in zone: UUID) throws -> URL {
        let sources = try urls(paths, in: zone)
        guard let first = sources.first else { throw StoreFailure.unavailableReference }
        for source in sources { try storage.validateImport(source) }
        let identities = try sources.map { try FileIdentity(url: $0) }
        let parent = first.deletingLastPathComponent()
        let target = Self.available(parent, stem: sources.count == 1 ? first.lastPathComponent : L("归档", "Archive"), ext: "zip")
        let stage = parent.appendingPathComponent(".pans-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = stage.appendingPathComponent("output.zip")
        let input: URL
        if sources.count == 1 { input = first }
        else {
            input = stage.appendingPathComponent("Archive")
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
            for source in sources {
                let copy = Self.available(input, stem: source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: copy)
            }
        }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, output.path]
        task.standardError = FileHandle.nullDevice; try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw FileActionError.compressionFailed }
        guard try sources.map({ try FileIdentity(url: $0) }) == identities else { throw CopyExportError.changed }
        try StorageEngine.atomicMove(output, target)
        try store.add([target], to: zone)
        return target
    }
    func copyToPasteboard(_ paths: [String], in zone: UUID, pasteboard: NSPasteboard) throws {
        let sources = try urls(paths, in: zone)
        pasteboard.clearContents()
        guard pasteboard.writeObjects(sources as [NSURL]) else { throw FileActionError.outputUnavailable }
    }
    func tags(_ names: [String], color: Int? = nil, paths: [String], in zone: UUID) throws {
        for url in try urls(paths, in: zone) {
            let values = Array(NSOrderedSet(array: names)) as? [String] ?? names
            try (url as NSURL).setResourceValue(values, forKey: .tagNamesKey)
            if let color { try (url as NSURL).setResourceValue(color, forKey: .labelNumberKey) }
        }
    }
    // A Trash destination may either request .delete or have already moved the URL.
    // Handle both paths, once, and retain records if the destination cannot be verified.
    func finishTrashDrag(_ items: [FileMoveItem], in zone: UUID,
                         recycler: (URL) throws -> URL = StorageEngine.recycle) throws {
        guard store.zones.contains(where: { $0.id == zone && !$0.locked }) else { throw StoreFailure.lockedZone }
        for item in items {
            if (try? FileIdentity(url: item.source)) == item.tracking.identity {
                _ = try storage.trash(item.source, sourceZone: zone, recycler: recycler)
            } else {
                _ = try storage.finishExternalTrash(item.source, tracking: item.tracking, sourceZone: zone)
            }
        }
    }
}
