import AppKit
import UniformTypeIdentifiers

enum CopyExportError: LocalizedError {
    case unavailable, changed, collision, invalidDestination
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("原文件暂不可用，未复制，也未移除分区引用。", "The original file is currently unavailable. No copy was made and the partition reference was kept.")
        case .changed: return L("复制期间原文件有变动，请重试。原文件和分区引用均保留。", "The original file changed while being copied. Try again. The original file and partition reference have been kept.")
        case .collision: return L("目标已有同名文件，未覆盖。请换一个位置或文件名。", "The destination already has a file with this name. Nothing was overwritten. Choose another location or name.")
        case .invalidDestination: return L("复制目标不可用，原文件和分区引用均保留。", "The copy destination is unavailable. The original file and partition reference have been kept.")
        }
    }
}

// A promise exposes a new copy, never the original URL. Finder and the native
// promise receiver both call this delegate with the final destination URL.
final class FileCopyRequest: NSObject, NSFilePromiseProviderDelegate {
    let sourcePath: String
    let tracking: TrackedReference
    let fileName: String
    let type: String
    let queue = OperationQueue()
    var result: ((Result<URL, Error>) -> Void)?
    init(source: URL) throws {
        let url = source.resolvingSymlinksInPath().standardizedFileURL
        guard StorageEngine.regular(url) else { throw CopyExportError.unavailable }
        sourcePath = url.path; tracking = try TrackedReference(url: url)
        fileName = url.lastPathComponent
        let contentType = UTType(filenameExtension: url.pathExtension) ?? .data
        type = (contentType.conforms(to: .data) ? contentType : .data).identifier
        super.init()
        queue.name = "com.andy.clearzones.export-copy"; queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }
    func sourceURL() throws -> URL {
        guard let value = ReferenceStore.resolve(sourcePath, tracking: tracking,
                  root: URL(fileURLWithPath: sourcePath).deletingLastPathComponent(), allowPersonalFiles: true),
              StorageEngine.regular(value.url) else { throw CopyExportError.unavailable }
        return value.url
    }
    func copy(to destination: URL) throws {
        let fm = FileManager.default, source = try sourceURL()
        let target = destination.standardizedFileURL
        guard target.isFileURL, target.path != source.path,
              target.lastPathComponent != ".", target.lastPathComponent != ".." else { throw CopyExportError.invalidDestination }
        guard !StorageEngine.exists(target.path) else { throw CopyExportError.collision }
        let parent = target.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".Pan's Desktop复制-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) } // Only this request's own staging directory.
        let staged = stage.appendingPathComponent("copy")
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try fm.copyItem(at: source, to: staged)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (try? FileIdentity(url: source)) == tracking.identity,
              before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate else { throw CopyExportError.changed }
        do { try StorageEngine.atomicMove(staged, target) } // Move only the NEW copy.
        catch StorageError.collision { throw CopyExportError.collision }
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { fileName }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try copy(to: url); result?(.success(url)); completionHandler(nil) }
        catch { result?(.failure(error)); completionHandler(error) }
    }
}

final class FileCopyPromise: NSFilePromiseProvider {
    let request: FileCopyRequest
    let referenceData: Data
    static let referenceType = NSPasteboard.PasteboardType("com.andy.clearzones.reference")
    static func make(source: URL, referenceData: Data, locked: Bool) throws -> FileCopyPromise? {
        guard !locked else { return nil }
        return try FileCopyPromise(source: source, referenceData: referenceData)
    }
    init(source: URL, referenceData: Data) throws {
        request = try FileCopyRequest(source: source); self.referenceData = referenceData
        super.init()
        fileType = request.type; delegate = request
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.referenceType]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.referenceType ? referenceData : super.pasteboardPropertyList(forType: type)
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.referenceType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}
