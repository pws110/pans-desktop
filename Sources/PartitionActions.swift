import Foundation

enum PartitionPlacement {
    static func next(toRightOf zones: [Zone], on screen: ZoneFrame) -> ZoneFrame {
        let gap = 18.0
        let width = min(300, max(1, screen.width - gap * 2))
        let height = min(280, max(1, screen.height - gap * 2))
        let left = screen.x + gap, right = screen.x + screen.width - gap
        let bottom = screen.y + gap, top = screen.y + screen.height - gap
        func free(_ frame: ZoneFrame) -> Bool {
            !zones.contains { z in frame.x < z.x + z.width + gap / 2 && frame.x + frame.width + gap / 2 > z.x && frame.y < z.y + z.height + gap / 2 && frame.y + frame.height + gap / 2 > z.y }
        }
        let anchor = zones.last
        var x = anchor.map { $0.x + $0.width + gap } ?? left
        var y = min(top - height, max(bottom, anchor.map { $0.y + $0.height - height } ?? top - height))
        for _ in 0..<512 {
            if x + width > right { x = left; y -= height + gap }
            if y < bottom { break }
            let frame = ZoneFrame(x: x, y: y, width: width, height: height)
            if free(frame) { return frame }
            x += width + gap
        }
        // A hand-arranged layout may leave space above the last-created row.
        y = top - height
        while y >= bottom {
            x = left
            while x + width <= right {
                let frame = ZoneFrame(x: x, y: y, width: width, height: height)
                if free(frame) { return frame }
                x += width + gap
            }
            y -= height + gap
        }
        return ZoneFrame(x: min(max(left, anchor.map { $0.x + $0.width + gap } ?? left), right - width), y: max(bottom, top - height), width: width, height: height)
    }
}

struct ArchivedPartition: Codable {
    let zone: Zone
    let index: Int
    let deletedAt: Date
}

enum PartitionDeletionError: LocalizedError {
    case notEmpty(Int)
    var errorDescription: String? {
        switch self {
        case .notEmpty(let count):
            return L("分区里还有 \(count) 个可用项目，请先移到桌面或其他已解锁分区。空分区或只剩原文件不可用条目的分区可以删除；不会删除原文件。", "This partition still has \(count) available items. Move them to the desktop or another unlocked partition first. Empty partitions and partitions containing only unavailable entries can be deleted. Original files will not be deleted.")
        }
    }
}

// The archive is written first and retained after restoration. If saving the
// active configuration fails or the app exits, the complete zone is recoverable.
// No operation here opens, moves, renames or deletes a referenced file.
final class PartitionArchive {
    private(set) var entries: [ArchivedPartition]
    let url: URL
    private let writer: (Data, URL) throws -> Void
    init(url: URL, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.url = url; self.writer = writer
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try JSONDecoder().decode([ArchivedPartition].self, from: Data(contentsOf: url))
        } else { entries = [] }
    }
    func restorable(in store: ReferenceStore) -> ArchivedPartition? {
        entries.reversed().first { entry in !store.zones.contains { $0.id == entry.zone.id } }
    }
    func validateRemoval(_ id: UUID, from store: ReferenceStore) throws {
        guard let index = store.zones.firstIndex(where: { $0.id == id }) else { return }
        let zone = store.zones[index]
        // Resolve current bookmarks, rather than trusting a stale unavailable badge.
        // Only metadata is archived; unavailable disk files are never touched.
        let available = zone.paths.filter { store.resolvedURL($0, in: id) != nil }.count
        guard available == 0 else { throw PartitionDeletionError.notEmpty(available) }
        guard zone.paths.isEmpty || !zone.locked else { throw StoreFailure.lockedZone }
    }
    func remove(_ id: UUID, from store: ReferenceStore) throws {
        guard let index = store.zones.firstIndex(where: { $0.id == id }) else { return }
        // Recheck at commit: a file may have reappeared during confirmation.
        try validateRemoval(id, from: store)
        let snapshot = store.zones
        var next = entries.filter { $0.zone.id != id }
        next.append(ArchivedPartition(zone: snapshot[index], index: index, deletedAt: Date()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer(encoder.encode(next), url)
        entries = next
        store.zones.remove(at: index)
        do { try store.save() } catch { store.zones = snapshot; throw error }
    }
    @discardableResult func restore(in store: ReferenceStore) throws -> Zone? {
        guard let entry = restorable(in: store) else { return nil }
        let snapshot = store.zones
        store.zones.insert(entry.zone, at: min(entry.index, store.zones.count))
        do { try store.save() } catch { store.zones = snapshot; throw error }
        return entry.zone
    }
}
