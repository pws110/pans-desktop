import Foundation
import Darwin

struct Membership: Codable, Equatable { let zone: UUID; let index: Int }
struct StorageMove: Codable {
    let from: String
    let to: String
    let identity: FileIdentity
    let device: UInt64
    let tracking: TrackedReference?
    let before: [Membership]
    let after: [Membership]
}
struct StorageRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let title: String
    let kind: String
    var moves: [StorageMove]
    var state = "pending"
    var reverses: UUID? = nil
    var orderChange: ZoneOrderChange? = nil
    var actionZones: [UUID]? = nil
}
struct ZoneOrderChange: Codable {
    let zone: UUID
    let before: [String]
    let after: [String]
    let beforeSort: String?
    let afterSort: String?
    var reversed: ZoneOrderChange { ZoneOrderChange(zone: zone, before: after, after: before, beforeSort: afterSort, afterSort: beforeSort) }
}
struct StorageJournal: Codable {
    var folders: [String: String] = [:]
    var records: [StorageRecord] = []
}
enum StorageError: LocalizedError {
    case unsupported, unavailable, collision(String), crossVolume, invalidFolder, journal, noUndo, failed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: return L("可收纳普通文档、图片和文件夹；系统目录、应用及符号链接不能移入。", "You can collect ordinary documents, images, and folders. System folders, apps, and symbolic links cannot be moved in.")
        case .unavailable: return L("文件或原位置已变动，请在访达中检查后重试。没有覆盖文件。", "The file or its original location has changed. Check it in Finder and try again. No files were overwritten.")
        case .collision(let name): return L("目标已有“\(name)”，未覆盖，也未移动本批文件。请更名或换一个分区。", "The destination already contains “\(name)”. No files in this batch were moved or overwritten. Rename the item or choose another partition.")
        case .crossVolume: return L("收纳暂只支持同一磁盘。外接盘文件请使用仅引用方式。", "Collect mode currently supports moves on the same disk only. Use references for files on external disks.")
        case .invalidFolder: return L("收纳目录已改变或不安全，已停止移动。请查看收纳文件夹。", "The storage folder has changed or is unsafe. Moving has stopped. Please check the storage folder.")
        case .journal: return L("操作记录或分区配置无法保存，尚未移动文件。", "The activity log or partition settings could not be saved. No files have been moved.")
        case .noUndo: return L("没有可撤销的收纳操作。", "There is no collection action to undo.")
        case .failed(let reason): return reason
        }
    }
}
final class StorageEngine {
    let references: ReferenceStore
    let home: URL
    let root: URL
    let journalURL: URL
    private(set) var journal: StorageJournal
    private let writer: (Data, URL) throws -> Void
    private let mover: (URL, URL) throws -> Void
    private let deviceOf: (URL) throws -> UInt64
    let fm = FileManager.default
    init(home: URL, references: ReferenceStore,
         writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         mover: @escaping (URL, URL) throws -> Void = StorageEngine.atomicMove,
         device: @escaping (URL) throws -> UInt64 = StorageEngine.device) throws {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.root = self.home.appendingPathComponent("收纳文件", isDirectory: true)
        self.journalURL = self.home.appendingPathComponent("Configuration/storage-journal.json")
        self.references = references; self.writer = writer; self.mover = mover; self.deviceOf = device
        if fm.fileExists(atPath: journalURL.path) {
            do { journal = try JSONDecoder().decode(StorageJournal.self, from: Data(contentsOf: journalURL)) }
            catch { throw StorageError.failed(L("收纳记录无法读取，已停止收纳，避免覆盖记录。", "The collection log could not be read. Collection has stopped to preserve the existing log.")) }
        } else { journal = StorageJournal() }
        try ensureRoot()
        for zone in references.zones { _ = try folder(zone.id) }
        try recoverByObservation()
    }
    var records: [StorageRecord] { journal.records }
    static func exists(_ path: String) -> Bool { var value = stat(); return lstat(path, &value) == 0 }
    static func regular(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }
    static func movableItem(_ url: URL) -> Bool {
        let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        return type == .typeRegular || type == .typeDirectory
    }
    static func device(_ url: URL) throws -> UInt64 {
        guard let n = try FileManager.default.attributesOfItem(atPath: url.path)[.systemNumber] as? NSNumber else { throw StorageError.unavailable }
        return n.uint64Value
    }
    // Same-volume atomic rename, with a kernel-level no-overwrite guarantee.
    // There is no copy/delete fallback, even if a volume changes during a drop.
    static func atomicMove(_ source: URL, _ target: URL) throws {
        let srcParent = source.deletingLastPathComponent(), dstParent = target.deletingLastPathComponent()
        // macOS can allow access to a known trashed item while denying directory
        // enumeration/open. Restore only that exact recorded Trash pathname; keep
        // the destination anchored to a no-follow directory fd and RENAME_EXCL.
        let userTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        if srcParent.path == userTrash, srcParent.resolvingSymlinksInPath().path == userTrash {
            let dst = open(dstParent.path, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
            guard dst >= 0 else { throw StorageError.unavailable }
            defer { close(dst) }
            if renameatx_np(AT_FDCWD, source.path, dst, target.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { throw StorageError.collision(target.lastPathComponent) }
                if errno == EXDEV { throw StorageError.crossVolume }
                throw StorageError.failed(L("恢复未完成：", "Restore incomplete: ") + String(cString: strerror(errno)))
            }
            return
        }
        let src = open(srcParent.path, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
        guard src >= 0 else { throw StorageError.unavailable }
        defer { close(src) }
        let dst = open(dstParent.path, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
        guard dst >= 0 else { throw StorageError.unavailable }
        defer { close(dst) }
        let result = renameatx_np(src, source.lastPathComponent, dst, target.lastPathComponent, UInt32(RENAME_EXCL))
        if result != 0 {
            if errno == EEXIST { throw StorageError.collision(target.lastPathComponent) }
            if errno == EXDEV { throw StorageError.crossVolume }
            throw StorageError.failed(L("移动未完成：", "Move incomplete: ") + String(cString: strerror(errno)))
        }
    }
    func ensureRoot() throws {
        if Self.exists(root.path) {
            guard (try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory,
                  root.resolvingSymlinksInPath().path == root.path else { throw StorageError.invalidFolder }
        } else { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
    }
    func folder(_ id: UUID) throws -> URL {
        try ensureRoot()
        guard let zone = references.zones.first(where: { $0.id == id }) else { throw StorageError.invalidFolder }
        if journal.folders[id.uuidString] == nil {
            var name = zone.title.trimmingCharacters(in: .whitespacesAndNewlines)
            name = String(name.filter { !"/\\:\n\r\0".contains($0) }.prefix(40))
            if name.isEmpty || name.hasPrefix(".") { name = "分区" }
            if journal.folders.values.contains(name) || Self.exists(root.appendingPathComponent(name).path) { name += "-" + id.uuidString.prefix(8) }
            let old = journal
            journal.folders[id.uuidString] = name
            do { try saveJournal() } catch { journal = old; throw error }
        }
        let name = journal.folders[id.uuidString]!
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw StorageError.invalidFolder }
        let url = root.appendingPathComponent(name, isDirectory: true)
        if Self.exists(url.path) {
            guard (try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory,
                  url.resolvingSymlinksInPath().path == url.path else { throw StorageError.invalidFolder }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        return url
    }
    func isManaged(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return canonical.path.hasPrefix(root.path + "/") && Self.movableItem(canonical)
    }
    func validateImport(_ url: URL) throws {
        guard url.isFileURL, Self.movableItem(url), fm.isReadableFile(atPath: url.path) else { throw StorageError.unsupported }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let path = canonical.path
        let blockedRoots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path, home.appendingPathComponent("Source").path, home.appendingPathComponent("Configuration").path]
        guard !canonical.pathComponents.contains(where: { c in c.hasPrefix(".") || [".app", ".framework", ".bundle"].contains(where: { c.lowercased().hasSuffix($0) }) }),
              !blockedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw StorageError.unsupported }
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values.isDirectory == true {
            let systemFolders: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory, .moviesDirectory, .musicDirectory, .applicationDirectory]
            let protected = [fm.homeDirectoryForCurrentUser] + systemFolders.compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            guard values.isPackage != true,
                  !protected.contains(where: { $0.resolvingSymlinksInPath().path == path }),
                  path != root.path, path != "/Volumes",
                  !(canonical.deletingLastPathComponent().path == root.path && journal.folders.values.contains(canonical.lastPathComponent)),
                  home.path != path, !home.path.hasPrefix(path == "/" ? "/" : path + "/") else { throw StorageError.unsupported }
        }
        if isManaged(canonical), let identity = try? FileIdentity(url: canonical),
           (references.zones.contains(where: { $0.references?.values.contains(where: { $0.identity == identity }) == true }) || records.contains(where: { $0.moves.contains(where: { $0.identity == identity }) })) { return }
        _ = try ReferenceStore.validated(canonical, root: home.appendingPathComponent("_no_sample_exception"), allowPersonalFiles: true)
    }
    func canCollect(_ urls: [URL], to destination: UUID? = nil, sourceZone: UUID? = nil) -> Bool {
        let ids = [destination, sourceZone].compactMap { $0 }
        return !urls.isEmpty && (try? validateUnlocked(ids)) != nil && urls.allSatisfy { (try? validateImport($0)) != nil }
    }
    func memberships(_ url: URL, identity: FileIdentity) -> [Membership] {
        references.zones.flatMap { zone in
            zone.paths.enumerated().compactMap { index, path in
                (path == url.path || zone.references?[path]?.identity == identity) ? Membership(zone: zone.id, index: index) : nil
            }
        }
    }
    func plan(_ source: URL, _ target: URL, after: [Membership]) throws -> StorageMove {
        guard Self.movableItem(source), source.path == target.path || !Self.exists(target.path) else {
            if Self.exists(target.path) { throw StorageError.collision(target.lastPathComponent) }
            throw StorageError.unavailable
        }
        guard !target.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw StorageError.invalidFolder }
        let identity = try FileIdentity(url: source), device = try deviceOf(source)
        guard device == (try deviceOf(target.deletingLastPathComponent())) else { throw StorageError.crossVolume }
        return StorageMove(from: source.path, to: target.path, identity: identity, device: device,
                           tracking: try? TrackedReference(url: source), before: memberships(source, identity: identity), after: after)
    }
    @discardableResult func collect(_ urls: [URL], to id: UUID, at insertion: Int? = nil, displayOrder: [String]? = nil, sourceZone: UUID? = nil) throws -> UUID? {
        let actions = [id] + [sourceZone].compactMap { $0 }
        try validateUnlocked(actions)
        let target = try folder(id)
        var seen = Set<String>(), moves: [StorageMove] = []
        for url in urls {
            try validateImport(url)
            let source = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(source.path).inserted else { continue }
            if source.deletingLastPathComponent().path == target.path,
               references.zones.first(where: { $0.id == id })!.paths.contains(source.path) { continue }
            moves.append(try plan(source, target.appendingPathComponent(source.lastPathComponent), after: [Membership(zone: id, index: references.zones.first { $0.id == id }!.paths.count + moves.count)]))
        }
        guard Set(moves.map { $0.to.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }).count == moves.count else { throw StorageError.collision(L("同名文件", "a file with the same name")) }
        let destination = references.zones.first { $0.id == id }!
        var orderChange: ZoneOrderChange?
        if let insertion {
            let base = GridOrder.normalized(displayOrder, members: destination.paths)
            let removed = Set(moves.flatMap { move in move.before.filter { $0.zone == id }.compactMap { member in
                destination.paths.indices.contains(member.index) ? destination.paths[member.index] : nil
            } })
            if moves.isEmpty { return try reorder(urls.map(\.path), in: id, at: insertion, displayOrder: base) }
            let incoming = urls.map { target.appendingPathComponent($0.lastPathComponent).path }
            let order = GridOrder.inserting(incoming, into: base, at: insertion, removing: removed)
            orderChange = ZoneOrderChange(zone: id, before: destination.paths, after: order, beforeSort: destination.sortOrder, afterSort: "manual")
        }
        return try execute(moves, title: L("收纳至“\(destination.title)”", "Collect into “\(destination.title)”"), kind: "collect", orderChange: orderChange, actionZones: actions)
    }
    @discardableResult func reorder(_ paths: [String], in id: UUID, at insertion: Int, displayOrder: [String]? = nil) throws -> UUID? {
        guard let zone = references.zones.first(where: { $0.id == id }), !paths.isEmpty,
              paths.allSatisfy(zone.paths.contains) else { throw StoreFailure.unavailableReference }
        guard !zone.locked else { throw StoreFailure.lockedZone }
        let base = GridOrder.normalized(displayOrder, members: zone.paths)
        let desired = GridOrder.inserting(paths, into: base, at: insertion)
        if desired == zone.paths && zone.sortOrder == "manual" { return nil }
        let order = ZoneOrderChange(zone: id, before: zone.paths, after: desired, beforeSort: zone.sortOrder, afterSort: "manual")
        return try execute([], title: L("调整“\(zone.title)”内的排列", "Reorder items in “\(zone.title)”"), kind: "reorder", orderChange: order, actionZones: [id])
    }
    @discardableResult func transferReferences(_ paths: [String], from source: UUID, to destination: UUID, at insertion: Int, displayOrder: [String]? = nil) throws -> UUID? {
        guard let from = references.zones.first(where: { $0.id == source }),
              let to = references.zones.first(where: { $0.id == destination }) else { throw StoreFailure.unavailableReference }
        guard !from.locked, !to.locked else { throw StoreFailure.lockedZone }
        if source == destination { return try reorder(paths, in: source, at: insertion, displayOrder: displayOrder) }
        var moves: [StorageMove] = [], seen = Set<String>()
        for path in paths {
            guard let url = references.resolvedURL(path, in: source) else { throw StoreFailure.unavailableReference }
            guard seen.insert(url.path).inserted else { continue }
            let identity = try FileIdentity(url: url)
            let keep = memberships(url, identity: identity).filter { $0.zone != source && $0.zone != destination }
            let after = keep + [Membership(zone: destination, index: to.paths.count + moves.count)]
            moves.append(try plan(url, url, after: after))
        }
        let removed = Set(moves.flatMap { $0.before }.filter { $0.zone == destination }.compactMap { to.paths.indices.contains($0.index) ? to.paths[$0.index] : nil })
        let desired = GridOrder.inserting(moves.map(\.to), into: GridOrder.normalized(displayOrder, members: to.paths), at: insertion, removing: removed)
        let order = ZoneOrderChange(zone: destination, before: to.paths, after: desired, beforeSort: to.sortOrder, afterSort: "manual")
        return try execute(moves, title: L("转移引用至“\(to.title)”", "Transfer references to “\(to.title)”"), kind: "reference-transfer", orderChange: order, actionZones: [source, destination])
    }
    private func plansIntoFolder(_ urls: [URL], path: String, in id: UUID, sourceZone: UUID?) throws -> [StorageMove] {
        try validateUnlocked([id] + [sourceZone].compactMap { $0 })
        guard let zone = references.zones.first(where: { $0.id == id }), !zone.locked else { throw StoreFailure.lockedZone }
        guard let folder = references.resolvedURL(path, in: id),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw StorageError.unavailable }
        try validateImport(folder)
        var seen = Set<String>(), names = Set<String>(), moves: [StorageMove] = []
        for url in urls {
            try validateImport(url)
            let source = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(source.path).inserted else { continue }
            guard source.path != folder.path, !folder.path.hasPrefix(source.path + "/") else { throw StorageError.invalidFolder }
            let name = source.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(name).inserted else { throw StorageError.collision(source.lastPathComponent) }
            moves.append(try plan(source, folder.appendingPathComponent(source.lastPathComponent), after: []))
        }
        return moves
    }
    func canMoveIntoFolder(_ urls: [URL], path: String, in id: UUID, sourceZone: UUID? = nil) -> Bool {
        !urls.isEmpty && (try? plansIntoFolder(urls, path: path, in: id, sourceZone: sourceZone)) != nil
    }
    @discardableResult func moveIntoFolder(_ urls: [URL], path: String, in id: UUID, sourceZone: UUID? = nil) throws -> UUID? {
        let moves = try plansIntoFolder(urls, path: path, in: id, sourceZone: sourceZone)
        return try execute(moves, title: L("移入文件夹“\(URL(fileURLWithPath: path).lastPathComponent)”", "Move into folder “\(URL(fileURLWithPath: path).lastPathComponent)”"), kind: "folder-move", actionZones: [id] + [sourceZone].compactMap { $0 })
    }
    func matches(_ path: String, _ expected: FileIdentity) -> Bool { Self.movableItem(URL(fileURLWithPath: path)) && (try? FileIdentity(url: URL(fileURLWithPath: path))) == expected }
    func locate(_ move: StorageMove) -> URL? {
        for path in [move.to, move.from] where matches(path, move.identity) { return URL(fileURLWithPath: path) }
        return ReferenceStore.resolve(move.to, tracking: move.tracking, root: references.root, allowPersonalFiles: true)?.url
    }
    var undoRecord: StorageRecord? {
        let reversed = Set(records.filter { $0.state == "done" }.compactMap(\.reverses))
        return records.reversed().first { $0.state == "done" && $0.reverses == nil && !reversed.contains($0.id) }
    }
    @discardableResult func undo() throws -> UUID? {
        guard let record = undoRecord else { throw StorageError.noUndo }
        var moves: [StorageMove] = []
        for move in record.moves.reversed() {
            guard let current = locate(move), current.path != move.from || move.from == move.to else { throw StorageError.unavailable }
            moves.append(try plan(current, URL(fileURLWithPath: move.from), after: move.before))
        }
        let actions = record.actionZones ?? legacyActionZones(record)
        return try execute(moves, title: L("撤销：", "Undo: ") + record.title, kind: "undo", reverses: record.id, orderChange: record.orderChange?.reversed, actionZones: actions)
    }
    func originalLocation(_ url: URL) -> (String, [Membership])? {
        guard isManaged(url), let identity = try? FileIdentity(url: url) else { return nil }
        let reversed = Set(records.filter { $0.state == "done" }.compactMap(\.reverses))
        for record in records.reversed() where record.state == "done" && record.kind == "collect" && !reversed.contains(record.id) {
            if let move = record.moves.first(where: { $0.identity == identity && !$0.from.hasPrefix(root.path + "/") }) { return (move.from, move.before) }
        }
        return nil
    }
    @discardableResult func returnToOriginal(_ url: URL, sourceZone: UUID? = nil) throws -> UUID? {
        guard let origin = originalLocation(url) else { throw StorageError.unavailable }
        return try execute([plan(url, URL(fileURLWithPath: origin.0), after: origin.1)], title: L("放回原位置", "Return to Original Location"), kind: "return", actionZones: [sourceZone].compactMap { $0 })
    }
    // Explicit move-out also handles legacy references already on the Desktop:
    // the physical file stays there and only the zone memberships are removed.
    @discardableResult func moveOut(_ url: URL, to target: URL, sourceZone: UUID? = nil) throws -> UUID? {
        try validateImport(url)
        guard !target.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw StorageError.invalidFolder }
        return try execute([plan(url, target, after: [])], title: L("移出分区至“\(target.deletingLastPathComponent().lastPathComponent)”", "Move out of partition to “\(target.deletingLastPathComponent().lastPathComponent)”"), kind: "export-move", actionZones: [sourceZone].compactMap { $0 })
    }
    @discardableResult func moveOut(_ urls: [URL], toDirectory directory: URL, sourceZone: UUID? = nil) throws -> UUID? {
        guard !directory.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw StorageError.invalidFolder }
        var seen = Set<String>(), names = Set<String>(), moves: [StorageMove] = []
        for url in urls {
            try validateImport(url)
            guard seen.insert(url.path).inserted else { continue }
            let key = url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw StorageError.collision(url.lastPathComponent) }
            moves.append(try plan(url, directory.appendingPathComponent(url.lastPathComponent), after: []))
        }
        return try execute(moves, title: L("移出 \(moves.count) 个文件至“\(directory.lastPathComponent)”", "Move \(moves.count) items out to “\(directory.lastPathComponent)”"), kind: "export-move", actionZones: [sourceZone].compactMap { $0 })
    }
    // Finder owns the actual native file-URL move. Reconcile only after the same
    // file identity is verified at its new location; a cancelled drag does nothing.
    @discardableResult func finishExternalMove(_ original: URL, tracking: TrackedReference, sameLocationAccepted: Bool = false, sourceZone: UUID? = nil) throws -> Bool {
        guard let found = ReferenceStore.resolve(original.path, tracking: tracking, root: references.root, allowPersonalFiles: true),
              Self.movableItem(found.url), !isManaged(found.url),
              found.url.path != original.path || sameLocationAccepted else { return false }
        let before = memberships(original, identity: tracking.identity)
        guard !before.isEmpty else { return true }
        let raw = StorageMove(from: original.path, to: found.url.path, identity: tracking.identity,
                              device: try Self.device(found.url), tracking: tracking, before: before, after: [])
        let move = preservingOtherLockedReferences([raw], excluding: [sourceZone].compactMap { $0 })[0]
        var record = StorageRecord(title: L("拖出分区移动", "Move out by dragging"), kind: "external-move", moves: [move])
        record.actionZones = [sourceZone].compactMap { $0 }
        record.state = "pending"
        let old = references.zones
        journal.records.append(record)
        do { try saveJournal() } catch { journal.records.removeLast(); throw StorageError.journal }
        do {
            try apply([move], forward: true)
            journal.records[journal.records.count - 1].state = "done"; try saveJournal()
            return true
        } catch {
            references.zones = old
            try? references.save()
            journal.records[journal.records.count - 1].state = "attention"; try? saveJournal()
            throw StorageError.failed(L("文件已由访达移动，分区记录未全部保存。文件仍保留在“\(found.url.path)”，请刷新后核对。", "Finder moved the file, but not all partition records were saved. The file remains at “\(found.url.path)”. Refresh and check the records."))
        }
    }
    static func recycle(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw StorageError.failed(L("已调用废纸篓，但未取得恢复位置，请在访达核对。", "Trash was requested, but the restore location was not returned. Please check in Finder.")) }
        return result as URL
    }
    // Use the macOS Trash API so Finder's Put Back remains available. The journal
    // stores the actual returned path, including any name chosen for collisions.
    @discardableResult func trash(_ url: URL, sourceZone: UUID? = nil, recycler: (URL) throws -> URL = StorageEngine.recycle) throws -> UUID? {
        try validateImport(url)
        let identity = try FileIdentity(url: url), old = references.zones
        let placeholder = journalURL.deletingLastPathComponent().appendingPathComponent("pending-trash-" + UUID().uuidString)
        let actions = [sourceZone].compactMap { $0 }
        try validateUnlocked(actions)
        var move = preservingOtherLockedReferences([try plan(url, placeholder, after: [])], excluding: actions)[0]
        var record = StorageRecord(title: L("移到废纸篓：", "Move to Trash: ") + url.lastPathComponent, kind: "trash", moves: [move])
        record.actionZones = actions
        try references.save()
        journal.records.append(record)
        do { try saveJournal() } catch { journal.records.removeLast(); throw StorageError.journal }
        var trashed: URL?
        do {
            guard matches(url.path, identity) else { throw StorageError.unavailable }
            let target = try recycler(url); trashed = target
            guard matches(target.path, identity), !Self.exists(url.path) else { throw StorageError.unavailable }
            move = StorageMove(from: url.path, to: target.path, identity: identity, device: move.device,
                               tracking: move.tracking, before: move.before, after: move.after)
            journal.records[journal.records.count - 1].moves = [move]; try saveJournal()
            try apply([move], forward: true)
            journal.records[journal.records.count - 1].state = "done"; try saveJournal()
            return record.id
        } catch {
            var restored = matches(url.path, identity)
            if let target = trashed, matches(target.path, identity), !Self.exists(url.path) {
                do { try mover(target, url); restored = true } catch { restored = false }
            }
            references.zones = old
            if restored { do { try references.save() } catch { restored = false } }
            journal.records[journal.records.count - 1].state = restored ? "cancelled" : "attention"
            try? saveJournal()
            throw StorageError.failed(restored ? L("移到废纸篓未完成，文件和分区项目已保留。", "Moving to Trash did not complete. The file and partition entry have been kept.") : L("移到废纸篓的记录未完成，文件未被永久删除，请在废纸篓和操作记录中核对。", "The Trash operation was not fully recorded. The file was not permanently deleted. Check Trash and Activity History."))
        }
    }
    private func apply(_ moves: [StorageMove], forward: Bool, orderChange: ZoneOrderChange? = nil) throws {
        // Remove the whole batch before restoring any membership. Undo reverses
        // filesystem moves; its order must not shift the original grid indices.
        let paths = Set(moves.flatMap { [$0.from, $0.to] })
        for i in references.zones.indices {
            let removed = references.zones[i].paths.filter { path in
                paths.contains(path) || moves.contains(where: { references.zones[i].references?[path]?.identity == $0.identity })
            }
            references.zones[i].paths.removeAll { removed.contains($0) }
            for old in removed { references.zones[i].references?.removeValue(forKey: old) }
        }
        var insertions: [(member: Membership, path: String, tracking: TrackedReference?)] = []
        for move in moves {
            let path = forward ? move.to : move.from, members = forward ? move.after : move.before
            let newReference = (try? TrackedReference(url: URL(fileURLWithPath: path))) ?? move.tracking
            for member in members { insertions.append((member, path, newReference)) }
        }
        for i in references.zones.indices {
            let entries = insertions.filter { $0.member.zone == references.zones[i].id }.sorted { $0.member.index < $1.member.index }
            for entry in entries {
                references.zones[i].paths.insert(entry.path, at: min(entry.member.index, references.zones[i].paths.count))
                if let tracking = entry.tracking {
                    if references.zones[i].references == nil { references.zones[i].references = [:] }
                    references.zones[i].references?[entry.path] = tracking
                }
            }
        }
        if let orderChange, let i = references.zones.firstIndex(where: { $0.id == orderChange.zone }) {
            references.zones[i].paths = GridOrder.normalized(forward ? orderChange.after : orderChange.before, members: references.zones[i].paths)
            references.zones[i].sortOrder = forward ? orderChange.afterSort : orderChange.beforeSort
        }
        try references.save()
    }
    private func validateUnlocked(_ ids: [UUID]) throws {
        // Only the explicit source/destination participates in an action.
        // A reference in another locked partition is not a filesystem lock.
        let involved = Set(ids)
        guard !references.zones.contains(where: { $0.locked && involved.contains($0.id) }) else { throw StoreFailure.lockedZone }
    }
    private func preservingOtherLockedReferences(_ moves: [StorageMove], excluding ids: [UUID]) -> [StorageMove] {
        let protected = Set(references.zones.filter { $0.locked && !ids.contains($0.id) }.map(\.id))
        return moves.map { move in
            let retained = move.before.filter { member in protected.contains(member.zone) && !move.after.contains(where: { $0.zone == member.zone }) }
            return StorageMove(from: move.from, to: move.to, identity: move.identity, device: move.device, tracking: move.tracking, before: move.before, after: move.after + retained)
        }
    }
    private func legacyActionZones(_ record: StorageRecord) -> [UUID] {
        var ids = record.orderChange.map { [$0.zone] } ?? []
        for move in record.moves {
            if record.kind == "collect" { ids += move.after.map(\.zone) }
            for zone in references.zones {
                guard let name = journal.folders[zone.id.uuidString] else { continue }
                let folder = root.appendingPathComponent(name).path
                if move.from.hasPrefix(folder + "/") { ids.append(zone.id) }
            }
        }
        if ids.isEmpty {
            let before = Set(record.moves.flatMap(\.before).map(\.zone))
            if before.count == 1 { ids += before }
        }
        return Array(Set(ids))
    }
    @discardableResult private func execute(_ originalMoves: [StorageMove], title: String, kind: String, reverses: UUID? = nil, orderChange: ZoneOrderChange? = nil, actionZones: [UUID] = []) throws -> UUID? {
        let actions = actionZones + (orderChange.map { [$0.zone] } ?? [])
        try validateUnlocked(actions)
        let moves = preservingOtherLockedReferences(originalMoves, excluding: actions)
        guard !moves.isEmpty || orderChange != nil else { return nil }
        // A selected parent plus its child cannot be planned as independent
        // atomic moves. Reject the whole batch before touching either item.
        for (index, move) in moves.enumerated() {
            guard !moves.enumerated().contains(where: { otherIndex, other in
                otherIndex != index && (move.from.hasPrefix(other.from + "/") || move.to.hasPrefix(other.from + "/"))
            }) else { throw StorageError.failed(L("不能同时移动一个文件夹及其内部项目，请只选择外层文件夹。", "A folder and its contents cannot be moved together. Select only the outer folder.")) }
        }
        try ensureRoot()
        for move in moves {
            guard matches(move.from, move.identity), (try deviceOf(URL(fileURLWithPath: move.from))) == move.device else { throw StorageError.unavailable }
            guard move.from == move.to || !Self.exists(move.to) else { throw StorageError.collision(URL(fileURLWithPath: move.to).lastPathComponent) }
            guard (try deviceOf(URL(fileURLWithPath: move.to).deletingLastPathComponent())) == move.device else { throw StorageError.crossVolume }
        }
        // Persist the intent before touching files. A failed intent write aborts.
        let oldZones = references.zones
        do { try references.save() } catch { throw StorageError.journal }
        var record = StorageRecord(title: title, kind: kind, moves: moves); record.reverses = reverses; record.orderChange = orderChange
        record.actionZones = Array(Set(actions))
        journal.records.append(record)
        do { try saveJournal() } catch { journal.records.removeLast(); throw StorageError.journal }
        var completed: [StorageMove] = []
        do {
            for move in moves {
                guard matches(move.from, move.identity) else { throw StorageError.unavailable }
                if move.from != move.to {
                    try mover(URL(fileURLWithPath: move.from), URL(fileURLWithPath: move.to))
                    completed.append(move)
                }
                guard matches(move.to, move.identity) else { throw StorageError.unavailable }
            }
            try apply(moves, forward: true, orderChange: orderChange)
            journal.records[journal.records.count - 1].state = "done"
            try saveJournal()
            return record.id
        } catch {
            var restored = true
            for move in completed.reversed() {
                guard matches(move.to, move.identity), !Self.exists(move.from) else { restored = false; continue }
                do { try mover(URL(fileURLWithPath: move.to), URL(fileURLWithPath: move.from)) } catch { restored = false }
            }
            references.zones = oldZones
            if restored { do { try references.save() } catch { restored = false } }
            journal.records[journal.records.count - 1].state = restored ? "cancelled" : "attention"
            try? saveJournal()
            if restored { throw StorageError.failed(L("操作未完成，本批移动已撤回。", "The action did not complete. All moves in this batch were rolled back. ") + error.localizedDescription) }
            throw StorageError.failed(L("操作未全部完成，已保留文件和记录。请在“操作记录”核对原位置与收纳位置，没有覆盖文件。", "The action did not fully complete. Files and records have been kept. Check original and storage locations in Activity History. No files were overwritten."))
        }
    }
    private func recoverByObservation() throws {
        var changed = false
        for index in journal.records.indices where journal.records[index].state == "pending" {
            let moves = journal.records[index].moves
            if moves.allSatisfy({ matches($0.to, $0.identity) }) {
                let old = references.zones
                do { try apply(moves, forward: true, orderChange: journal.records[index].orderChange); journal.records[index].state = "done" }
                catch { references.zones = old; throw error }
            } else if moves.allSatisfy({ matches($0.from, $0.identity) }) {
                journal.records[index].state = "cancelled"
            } else {
                journal.records[index].state = "attention"
                // Keep the old references; their bookmarks can observe actual locations.
            }
            changed = true
        }
        if changed { try saveJournal() }
    }
    func saveJournal() throws {
        try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer(encoder.encode(journal), journalURL)
    }
}
