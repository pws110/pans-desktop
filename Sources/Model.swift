import Foundation
import CoreFoundation
import CoreGraphics
import UniformTypeIdentifiers

struct Zone: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var paths: [String] = []
    var x: Double = 0
    var y: Double = 0
    var width: Double = 300
    var height: Double = 280
    var locked = false
    var organizeFiles: Bool? = nil
    var collapsed: Bool? = nil
    var expandedHeight: Double? = nil
    var maximized: Bool? = nil
    var restoreFrame: ZoneFrame? = nil
    var sortOrder: String? = nil
    var usesStorage: Bool { organizeFiles ?? true }
    var isCollapsed: Bool { collapsed ?? false }
    var isMaximized: Bool { maximized ?? false }
    // Optional for migration from earlier path-only configurations.
    var references: [String: TrackedReference]? = nil
}
struct ZoneFrame: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
}
struct ReferenceDrag: Codable {
    let zone: UUID
    let path: String
    var paths: [String]? = nil
    var sessionID: UUID? = nil
    var allPaths: [String] { paths ?? [path] }
}

enum GridOrder {
    static func normalized(_ preferred: [String]?, members: [String]) -> [String] {
        let allowed = Set(members)
        var seen = Set<String>()
        return ((preferred ?? []) + members).filter { allowed.contains($0) && seen.insert($0).inserted }
    }
    // The gap refers to the order BEFORE removing the moving items.
    static func inserting(_ incoming: [String], into order: [String], at gap: Int, removing: Set<String> = []) -> [String] {
        var seen = Set<String>()
        let items = incoming.filter { seen.insert($0).inserted }
        let removed = removing.union(items)
        let clamped = min(max(0, gap), order.count)
        let insertion = order.prefix(clamped).filter { !removed.contains($0) }.count
        var result = order.filter { !removed.contains($0) }
        result.insert(contentsOf: items, at: min(insertion, result.count))
        return result
    }
}
struct GridDropCell {
    let path: String
    let rect: CGRect // Coordinates increase from top to bottom.
}
struct GridDropTarget: Equatable {
    let index: Int
    let rect: CGRect?
    let trailing: Bool
    var folderPath: String? = nil
}
enum GridDropLayout {
    static let rowHeight: Double = 122
    static func target(at point: CGPoint, cells: [GridDropCell], order: [String]) -> GridDropTarget {
        let indices = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let available = cells.filter { indices[$0.path] != nil && !$0.rect.isEmpty }
        guard !available.isEmpty else { return GridDropTarget(index: order.count, rect: nil, trailing: false) }
        let first = available.min { indices[$0.path]! < indices[$1.path]! }!
        let last = available.max { indices[$0.path]! < indices[$1.path]! }!
        if point.y < first.rect.minY { return GridDropTarget(index: indices[first.path]!, rect: first.rect, trailing: false) }
        if point.y > last.rect.maxY { return GridDropTarget(index: indices[last.path]! + 1, rect: last.rect, trailing: true) }
        let nearest = available.min { a, b in
            func distance(_ r: CGRect) -> CGFloat { max(max(r.minY - point.y, 0), point.y - r.maxY) }
            let da = distance(a.rect), db = distance(b.rect)
            return da == db ? a.rect.minY < b.rect.minY : da < db
        }!
        let row = available.filter { abs($0.rect.midY - nearest.rect.midY) < 4 }.sorted { $0.rect.minX < $1.rect.minX }
        let cell = row.first { point.x <= $0.rect.midX } ?? row.last!
        let after = point.x > cell.rect.midX
        return GridDropTarget(index: indices[cell.path]! + (after ? 1 : 0), rect: cell.rect, trailing: after)
    }
}
extension Zone {
    var orderedPaths: [String] {
        func name(_ a: String, _ b: String) -> Bool { URL(fileURLWithPath: a).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: b).lastPathComponent) == .orderedAscending }
        switch sortOrder ?? "manual" {
        case "name": return paths.sorted(by: name)
        case "type": return paths.sorted {
            let a = URL(fileURLWithPath: $0).pathExtension.lowercased(), b = URL(fileURLWithPath: $1).pathExtension.lowercased()
            return a == b ? name($0, $1) : a < b
        }
        case "modified":
            let dates = Dictionary(uniqueKeysWithValues: paths.map { ($0, ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date) ?? .distantPast) })
            return paths.sorted { dates[$0]! == dates[$1]! ? name($0, $1) : dates[$0]! > dates[$1]! }
        default: return paths
        }
    }
}

struct FileIdentity: Codable, Equatable {
    let volume: String
    let file: UInt64
    let creationTime: Double?
    init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber else { throw StoreFailure.unsupportedFile }
        volume = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? "device-\(device.uint64Value)"
        file = number.uint64Value
        creationTime = (attrs[.creationDate] as? Date)?.timeIntervalSinceReferenceDate
    }
}
struct TrackedReference: Codable, Equatable {
    let bookmark: Data
    let identity: FileIdentity
    let fileReferenceURL: String?
    init(url: URL) throws {
        identity = try FileIdentity(url: url)
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let pathURL = CFURLCreateWithFileSystemPath(nil, url.path as CFString, .cfurlposixPathStyle, directory)
        if let pathURL, let reference = CFURLCreateFileReferenceURL(nil, pathURL, nil) {
            fileReferenceURL = CFURLGetString(reference.takeRetainedValue()) as String
        } else { fileReferenceURL = nil }
        // Data stays in our own JSON. No alias file, xattr, or security grant
        // is created on the original file.
        bookmark = try url.bookmarkData(options: [.withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
struct ResolvedReference {
    let url: URL
    let tracking: TrackedReference?
}
struct ReferenceRefresh {
    var zones: [Zone]
    var unavailable: Set<String>
}

enum StoreFailure: LocalizedError {
    case outsideSamples, unsupportedFile, unreadableConfig, unavailableReference, lockedZone
    var errorDescription: String? {
        switch self {
        case .outsideSamples: return "试用版只接受 TestFiles 里的测试文件。原文件不会被移动。"
        case .unsupportedFile: return "请拖入可读取的文档、图片或普通文件夹。"
        case .unreadableConfig: return "配置无法读取，已停止加载，避免覆盖原配置。"
        case .unavailableReference: return "原文件暂不可用，引用已保留。请检查文件或磁盘是否可用；也可移出旧引用后重新拖入。"
        case .lockedZone: return "分区已锁定，请先解锁后再移动或增减文件。仍可正常打开和预览。"
        }
    }
}
final class ReferenceStore {
    let root: URL
    let config: URL
    var zones: [Zone]
    private(set) var unavailable: Set<String> = []
    let allowPersonalFiles: Bool
    init(root: URL, config: URL, allowPersonalFiles: Bool = false) throws {
        self.allowPersonalFiles = allowPersonalFiles
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.config = config
        if FileManager.default.fileExists(atPath: config.path) {
            do { zones = try JSONDecoder().decode([Zone].self, from: Data(contentsOf: config)) }
            catch { throw StoreFailure.unreadableConfig }
        } else { zones = [] }
    }
    static func validated(_ url: URL, root: URL, allowPersonalFiles: Bool) throws -> String {
        guard url.isFileURL else { throw StoreFailure.unsupportedFile }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw StoreFailure.unsupportedFile }
        // Keep a folder as one item; never enumerate or rewrite its contents.
        if path.hasPrefix(root.path + "/") { return path }
        guard allowPersonalFiles else { throw StoreFailure.outsideSamples }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        if values.isDirectory == true, values.isPackage != true,
           !["app", "framework", "bundle"].contains(resolved.pathExtension.lowercased()),
           fm.isReadableFile(atPath: path) { return path }
        let ext = resolved.pathExtension.lowercased()
        let documents: Set<String> = ["pdf", "txt", "md", "markdown", "rtf", "doc", "docx", "odt", "pages", "xls", "xlsx", "ods", "numbers", "ppt", "pptx", "odp", "key", "csv", "tsv", "epub"]
        let type = UTType(filenameExtension: ext)
        guard values.isRegularFile == true, fm.isReadableFile(atPath: path),
              documents.contains(ext) || type?.conforms(to: .image) == true else { throw StoreFailure.unsupportedFile }
        return path
    }
    func validated(_ url: URL) throws -> String { try Self.validated(url, root: root, allowPersonalFiles: allowPersonalFiles) }

    static func resolve(_ path: String, tracking: TrackedReference?, root: URL, allowPersonalFiles: Bool) -> ResolvedReference? {
        let original = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        func permitted(_ url: URL) -> Bool {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
                  !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes") else { return false }
            return allowPersonalFiles || url.path.hasPrefix(root.path + "/")
        }
        guard let tracking else {
            guard permitted(original), (try? validated(original, root: root, allowPersonalFiles: allowPersonalFiles)) != nil else { return nil }
            return ResolvedReference(url: original, tracking: try? TrackedReference(url: original))
        }
        if permitted(original), (try? FileIdentity(url: original)) == tracking.identity {
            return ResolvedReference(url: original, tracking: tracking)
        }
        // File-ID URLs handle an old pathname being occupied by a new file.
        // They are only a verified fallback; bookmarks remain the durable record.
        var candidates: [URL] = []
        if let value = tracking.fileReferenceURL,
           let reference = CFURLCreateWithString(nil, value as CFString, nil),
           let found = CFURLCreateFilePathURL(nil, reference, nil),
           let path = CFURLCopyFileSystemPath(found.takeRetainedValue(), .cfurlposixPathStyle) {
            candidates.append(URL(fileURLWithPath: path as String))
        }
        var stale = false
        if let found = try? URL(resolvingBookmarkData: tracking.bookmark,
                               options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                               relativeTo: nil, bookmarkDataIsStale: &stale) { candidates.append(found) }
        for found in candidates {
            let url = found.resolvingSymlinksInPath().standardizedFileURL
            // A path may now contain an unrelated file. Never silently bind to it.
            guard permitted(url), (try? FileIdentity(url: url)) == tracking.identity else { continue }
            let refreshed = (stale || url.path != path) ? (try? TrackedReference(url: url)) : nil
            return ResolvedReference(url: url, tracking: refreshed ?? tracking)
        }
        return nil
    }

    func resolvedURL(_ path: String, in id: UUID) -> URL? {
        guard let zone = zones.first(where: { $0.id == id }), zone.paths.contains(path) else { return nil }
        return Self.resolve(path, tracking: zone.references?[path], root: root, allowPersonalFiles: allowPersonalFiles)?.url
    }
    // Pure snapshot calculation: the app runs this on a utility queue. Only
    // the main-thread commit below writes our configuration.
    static func refreshed(_ snapshot: [Zone], root: URL, allowPersonalFiles: Bool) -> ReferenceRefresh {
        var result = ReferenceRefresh(zones: snapshot, unavailable: [])
        for index in result.zones.indices {
            let zone = snapshot[index]
            var paths: [String] = []
            var references: [String: TrackedReference] = [:]
            for path in zone.paths {
                let resolved = resolve(path, tracking: zone.references?[path], root: root, allowPersonalFiles: allowPersonalFiles)
                let newPath = resolved?.url.path ?? path
                if !paths.contains(newPath) { paths.append(newPath) }
                if let reference = resolved?.tracking ?? zone.references?[path] { references[newPath] = reference }
                if resolved == nil { result.unavailable.insert(newPath) }
            }
            result.zones[index].paths = paths
            result.zones[index].references = references.isEmpty ? nil : references
        }
        return result
    }
    @discardableResult func applyRefresh(_ result: ReferenceRefresh, basedOn snapshot: [Zone]) throws -> Bool {
        // Discard work that raced with a drag, removal, rename, or layout edit.
        guard zones == snapshot else { return false }
        let changed = result.zones != zones || result.unavailable != unavailable
        if result.zones != zones {
            let previous = zones
            zones = result.zones
            do { try save() } catch { zones = previous; throw error }
        }
        unavailable = result.unavailable
        return changed
    }
    @discardableResult func refreshReferences() throws -> Bool {
        let snapshot = zones
        return try applyRefresh(Self.refreshed(snapshot, root: root, allowPersonalFiles: allowPersonalFiles), basedOn: snapshot)
    }
    func add(_ urls: [URL], to id: UUID, from source: UUID? = nil, at insertion: Int? = nil, displayOrder: [String]? = nil) throws {
        let paths = try urls.map { try validated($0) }
        guard let destination = zones.firstIndex(where: { $0.id == id }) else { return }
        guard !zones[destination].locked, source == nil || !zones.contains(where: { $0.id == source && $0.locked }) else { throw StoreFailure.lockedZone }
        let previous = zones
        let baseOrder = GridOrder.normalized(displayOrder, members: zones[destination].paths)
        for path in paths {
            let reference = try? TrackedReference(url: URL(fileURLWithPath: path))
            if !zones[destination].paths.contains(path) { zones[destination].paths.append(path) }
            if let reference {
                if zones[destination].references == nil { zones[destination].references = [:] }
                zones[destination].references?[path] = reference
            }
        }
        if let source, source != id, let index = zones.firstIndex(where: { $0.id == source }) {
            zones[index].paths.removeAll { paths.contains($0) }
            for path in paths { zones[index].references?.removeValue(forKey: path) }
        }
        if let insertion {
            zones[destination].paths = GridOrder.inserting(paths, into: baseOrder, at: insertion)
            zones[destination].sortOrder = "manual"
        }
        do { try save() } catch { zones = previous; throw error }
        unavailable.subtract(paths)
    }
    func transfer(_ path: String, from source: UUID, to destination: UUID) throws {
        try transfer([path], from: source, to: destination)
    }
    func transfer(_ paths: [String], from source: UUID, to destination: UUID, at insertion: Int? = nil, displayOrder: [String]? = nil) throws {
        guard let sourceIndex = zones.firstIndex(where: { $0.id == source }),
              let destinationIndex = zones.firstIndex(where: { $0.id == destination }) else { throw StoreFailure.unavailableReference }
        guard !zones[sourceIndex].locked, !zones[destinationIndex].locked else { throw StoreFailure.lockedZone }
        var resolvedPaths: [(String, ResolvedReference)] = []
        for path in paths {
            guard zones[sourceIndex].paths.contains(path),
                  let resolved = Self.resolve(path, tracking: zones[sourceIndex].references?[path], root: root, allowPersonalFiles: allowPersonalFiles) else { throw StoreFailure.unavailableReference }
            resolvedPaths.append((path, resolved))
        }
        let previous = zones, oldUnavailable = unavailable
        let baseOrder = GridOrder.normalized(displayOrder, members: zones[destinationIndex].paths)
        for (path, resolved) in resolvedPaths {
            if source == destination, resolved.url.path == path { continue }
            zones[sourceIndex].paths.removeAll { $0 == path }
            zones[sourceIndex].references?.removeValue(forKey: path)
            let newPath = resolved.url.path
            if !zones[destinationIndex].paths.contains(newPath) { zones[destinationIndex].paths.append(newPath) }
            if let reference = resolved.tracking {
                if zones[destinationIndex].references == nil { zones[destinationIndex].references = [:] }
                zones[destinationIndex].references?[newPath] = reference
            }
            unavailable.remove(path); unavailable.remove(newPath)
        }
        if let insertion {
            zones[destinationIndex].paths = GridOrder.inserting(resolvedPaths.map { $0.1.url.path }, into: baseOrder, at: insertion, removing: Set(paths))
            zones[destinationIndex].sortOrder = "manual"
        }
        do { try save() } catch { zones = previous; unavailable = oldUnavailable; throw error }
    }
    func reorder(_ paths: [String], in id: UUID, at insertion: Int, displayOrder: [String]? = nil) throws {
        guard let i = zones.firstIndex(where: { $0.id == id }), !paths.isEmpty,
              paths.allSatisfy(zones[i].paths.contains) else { throw StoreFailure.unavailableReference }
        guard !zones[i].locked else { throw StoreFailure.lockedZone }
        let previous = zones
        let order = GridOrder.normalized(displayOrder, members: zones[i].paths)
        zones[i].paths = GridOrder.inserting(paths, into: order, at: insertion)
        zones[i].sortOrder = "manual"
        if zones == previous { return }
        do { try save() } catch { zones = previous; throw error }
    }
    func remove(_ path: String, from id: UUID) throws {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        guard !zones[index].locked else { throw StoreFailure.lockedZone }
        let previous = zones
        zones[index].paths.removeAll { $0 == path }; zones[index].references?.removeValue(forKey: path)
        do { try save() } catch { zones = previous; throw error }
        if !zones.contains(where: { $0.paths.contains(path) }) { unavailable.remove(path) }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(zones).write(to: config, options: .atomic)
    }
}

extension Zone {
    var frameValue: ZoneFrame { ZoneFrame(x: x, y: y, width: width, height: height) }
    mutating func setFrame(_ frame: ZoneFrame) { x = frame.x; y = frame.y; width = frame.width; height = frame.height }
    func contentFrame(on screen: ZoneFrame, itemCount: Int, extraHeight: Double = 0) -> ZoneFrame {
        let base = frameValue
        let overhead = 110.0 + extraHeight, rowHeight = 132.0, columnWidth = 86.0
        let currentColumns = max(1, Int((width - 40) / columnWidth))
        let currentRows = max(1, Int((height - overhead + 10) / rowHeight))
        guard itemCount > max(2, currentColumns * currentRows) else { return base }
        let maxColumns = max(1, Int((screen.width - 40) / columnWidth))
        let maxRows = max(1, Int((screen.height - overhead + 10) / rowHeight))
        let expandedWidth: Double, expandedHeight: Double
        if itemCount >= maxColumns * maxRows {
            expandedWidth = screen.width; expandedHeight = screen.height
        } else {
            let balanced = Int(ceil(sqrt(Double(itemCount) * screen.width / screen.height * rowHeight / columnWidth)))
            let columnsToFitHeight = Int(ceil(Double(itemCount) / Double(maxRows)))
            let columns = min(maxColumns, max(currentColumns, max(balanced, columnsToFitHeight)))
            let rows = Int(ceil(Double(itemCount) / Double(columns)))
            expandedWidth = min(screen.width, max(width, 40 + Double(columns) * columnWidth))
            expandedHeight = min(screen.height, max(height, overhead + Double(rows) * rowHeight - 10))
        }
        // Keep the top edge and the nearest horizontal screen edge as anchors.
        // Only shift farther when the expanded content reaches the screen edge.
        let right = x + width, top = y + height
        let anchorRight = screen.x + screen.width - right < x - screen.x
        let proposedX = anchorRight ? right - expandedWidth : x
        return ZoneFrame(x: min(max(screen.x, proposedX), screen.x + screen.width - expandedWidth),
                         y: min(max(screen.y, top - expandedHeight), screen.y + screen.height - expandedHeight),
                         width: expandedWidth, height: expandedHeight)
    }
    mutating func toggleMaximum(on screen: ZoneFrame, itemCount: Int? = nil, extraHeight: Double = 0) {
        if isMaximized {
            if let saved = restoreFrame { setFrame(saved) }
            maximized = false; restoreFrame = nil
        } else {
            if isCollapsed { toggleCollapsed() }
            let target = contentFrame(on: screen, itemCount: itemCount ?? paths.count, extraHeight: extraHeight)
            guard target != frameValue else { return }
            restoreFrame = frameValue; setFrame(target); maximized = true
        }
    }
    mutating func toggleCollapsed() {
        if isMaximized, let saved = restoreFrame { setFrame(saved); maximized = false; restoreFrame = nil }
        let top = y + height
        if isCollapsed {
            height = max(180, expandedHeight ?? 280); collapsed = false
        } else {
            expandedHeight = height; height = 48; collapsed = true
        }
        y = top - height
    }
}
