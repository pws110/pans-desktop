import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: " + label)
}
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try fm.createDirectory(at: base, withIntermediateDirectories: false)
let samples = base.appendingPathComponent("TestFiles", isDirectory: true)
try fm.createDirectory(at: samples, withIntermediateDirectories: false)
let live = samples.appendingPathComponent("全新保留文档.txt"), relocated = samples.appendingPathComponent("全新改名文档.txt")
try Data("new fixture, never delete or rewrite".utf8).write(to: live)
let content = try Data(contentsOf: live), identity = try FileIdentity(url: live)
let missingPath = samples.appendingPathComponent("从未存在的失效文档.xlsx").path
let store = try ReferenceStore(root: samples, config: base.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
store.zones = [Zone(title: "只有失效条目", paths: [missingPath]), Zone(title: "混合分区", paths: [missingPath]), Zone(title: "其他锁定区", paths: [missingPath], locked: true)]
let missingID = store.zones[0].id, mixedID = store.zones[1].id, lockedID = store.zones[2].id
try store.add([live], to: mixedID); try store.save()
let archive = try PartitionArchive(url: base.appendingPathComponent("Configuration/deleted-partitions.json"))
let missingZone = store.zones[0]
try archive.validateRemoval(missingID, from: store); try archive.remove(missingID, from: store)
try check(!store.zones.contains { $0.id == missingID }, "unavailable-only partition can be removed")
try check(archive.entries.last?.zone == missingZone, "archival removal preserves all unavailable records and geometry")
try check(try archive.restore(in: store) == missingZone, "unavailable partition is recoverable with original records")
do { try archive.remove(mixedID, from: store); throw NSError(domain: "mixed unexpectedly removed", code: 1) }
catch PartitionDeletionError.notEmpty(let count) { try check(count == 1, "mixed partition blocks deletion for available file only") }
try store.remove(missingPath, from: mixedID)
try check(store.zones.first { $0.id == mixedID }?.paths == [live.path], "individual stale removal keeps available sibling")
try check(store.zones.first { $0.id == missingID }?.paths == [missingPath] && store.zones.first { $0.id == lockedID }?.paths == [missingPath], "individual removal does not remove references in other partitions")
do { try store.remove(missingPath, from: lockedID); throw NSError(domain: "locked removal", code: 1) }
catch StoreFailure.lockedZone { print("PASS: locked zone blocks individual stale removal") }
do { try archive.remove(lockedID, from: store); throw NSError(domain: "locked partition removal", code: 1) }
catch StoreFailure.lockedZone { print("PASS: locked unavailable-only partition requires unlocking itself") }
// A stale badge must not allow deleting a file that has returned at confirmation.
try archive.validateRemoval(missingID, from: store)
try Data("newly returned fixture".utf8).write(to: URL(fileURLWithPath: missingPath))
do { try archive.remove(missingID, from: store); throw NSError(domain: "reappeared file removal", code: 1) }
catch PartitionDeletionError.notEmpty { print("PASS: commit rechecks a file which returned during confirmation") }
// Bookmarks resolve external renames even when the displayed path is gone.
try fm.moveItem(at: live, to: relocated)
try check(store.resolvedURL(live.path, in: mixedID)?.path == relocated.path, "renamed live fixture remains resolvable by bookmark")
do { try archive.remove(mixedID, from: store); throw NSError(domain: "renamed live partition removal", code: 1) }
catch PartitionDeletionError.notEmpty { print("PASS: renamed live reference is not mistaken for an unavailable-only partition") }
try check(FileIdentity(url: relocated) == identity && Data(contentsOf: relocated) == content, "original available fixture identity and bytes preserved")
let reopened = try ReferenceStore(root: samples, config: store.config, allowPersonalFiles: true)
try check(reopened.zones == store.zones, "individual removals and partition restoration persist")
print("ALL UNAVAILABLE REMOVAL TESTS PASSED; only new isolated fixtures")
