import Foundation
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let fm = FileManager.default
let temp = fm.temporaryDirectory.appendingPathComponent("clearzones-tests-" + UUID().uuidString)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }
let samples = temp.appendingPathComponent("samples")
try fm.createDirectory(at: samples, withIntermediateDirectories: true)
let doc = samples.appendingPathComponent("document.txt")
let original = Data("sample content".utf8)
try original.write(to: doc)
let outside = temp.appendingPathComponent("outside.txt")
try Data("outside content".utf8).write(to: outside)
let link = samples.appendingPathComponent("outside-link")
try fm.createSymbolicLink(at: link, withDestinationURL: outside)
let config = temp.appendingPathComponent("configuration/zones.json")
let store = try ReferenceStore(root: samples, config: config)
store.zones = [Zone(title:"A"), Zone(title:"B")]
let a = store.zones[0].id, b = store.zones[1].id
try store.add([doc, doc], to: a)
check(store.zones[0].paths.count == 1, "duplicate references")
try store.add([doc], to: b, from: a)
check(store.zones[0].paths.isEmpty && store.zones[1].paths.count == 1, "cross-zone transfer")
check(try Data(contentsOf: doc) == original, "original changed")
for forbidden in [outside, link] {
 do { try store.add([forbidden], to: a); fatalError("outside path accepted") }
 catch StoreFailure.outsideSamples { }
}
let loaded = try ReferenceStore(root: samples, config: config)
check(loaded.zones[1].paths == [doc.path], "persistence failed")
loaded.zones[1].paths.removeAll(); try loaded.save()
check(fm.fileExists(atPath: doc.path), "removing reference deleted original")
let invalid = Data("invalid config".utf8); try invalid.write(to: config)
do { _ = try ReferenceStore(root: samples, config: config); fatalError("invalid config accepted") }
catch StoreFailure.unreadableConfig { }
check(try Data(contentsOf: config) == invalid, "bad config overwritten")
print("PASS: reference transfer, duplicate prevention, original preservation, outside-path and symlink rejection, persistence, reference removal, corrupt-config preservation")

let blocked = temp.appendingPathComponent("blocked")
try Data("not a directory".utf8).write(to: blocked)
let failing = try ReferenceStore(root: samples, config: blocked.appendingPathComponent("zones.json"))
failing.zones = [Zone(title: "source", paths: [doc.path]), Zone(title: "destination")]
let initial = failing.zones.map(\.paths)
do { try failing.add([doc], to: failing.zones[1].id, from: failing.zones[0].id); fatalError("write unexpectedly succeeded") }
catch { check(failing.zones.map(\.paths) == initial, "rollback on save failure") }
print("PASS: failed configuration write rolls back the reference transfer")

// Personal imports are outside TestFiles and deliberately read-only.
let personalDir = temp.appendingPathComponent("personal-documents")
try fm.createDirectory(at: personalDir, withIntermediateDirectories: true)
let personalDoc = personalDir.appendingPathComponent("我的文档.txt")
let personalImage = personalDir.appendingPathComponent("我的图片.png")
try original.write(to: personalDoc)
let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7V8AAAAASUVORK5CYII=")!
try imageData.write(to: personalImage)
for url in [personalDoc, personalImage] { try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
let docAttrs = try fm.attributesOfItem(atPath: personalDoc.path)
let imageAttrs = try fm.attributesOfItem(atPath: personalImage.path)
let personalConfig = temp.appendingPathComponent("personal-config/zones.json")
let personal = try ReferenceStore(root: samples, config: personalConfig, allowPersonalFiles: true)
personal.zones = [Zone(title: "常用"), Zone(title: "图片")]
let first = personal.zones[0].id, second = personal.zones[1].id
try personal.add([personalDoc, personalImage, personalDoc], to: first)
check(personal.zones[0].paths.count == 2, "personal imports or dedup failed")
try personal.add([personalDoc], to: second, from: first)
check(personal.zones[0].paths == [personalImage.path] && personal.zones[1].paths == [personalDoc.path], "personal cross-zone transfer failed")
let personalReloaded = try ReferenceStore(root: samples, config: personalConfig, allowPersonalFiles: true)
check(personalReloaded.zones.map(\.paths) == personal.zones.map(\.paths), "personal persistence failed")
personalReloaded.zones[1].paths.removeAll(); try personalReloaded.save()
let personalLink = personalDir.appendingPathComponent("文档链接.txt")
try fm.createSymbolicLink(at: personalLink, withDestinationURL: personalDoc)
check(try personal.validated(personalLink) == personalDoc.path, "document symlink reference failed")
let script = personalDir.appendingPathComponent("script.sh")
try Data("echo test".utf8).write(to: script)
let application = personalDir.appendingPathComponent("Example.app")
try fm.createDirectory(at: application, withIntermediateDirectories: true)
check(try personal.validated(personalDir) == personalDir.path, "ordinary personal folder reference rejected")
for forbidden in [script, application, URL(string: "https://example.com/image.png")!, personalDir.appendingPathComponent("missing.pdf")] {
 do { _ = try personal.validated(forbidden); fatalError("unsupported personal import accepted") }
 catch StoreFailure.unsupportedFile { }
}
let beforeBatch = personal.zones.map(\.paths)
do { try personal.add([personalDoc, script], to: second); fatalError("invalid batch accepted") }
catch StoreFailure.unsupportedFile { check(personal.zones.map(\.paths) == beforeBatch, "partial batch mutated references") }
for (url, contents, attrs) in [(personalDoc, original, docAttrs), (personalImage, imageData, imageAttrs)] {
 check(try Data(contentsOf: url) == contents, "personal content changed")
 let after = try fm.attributesOfItem(atPath: url.path)
 for key in [FileAttributeKey.modificationDate, .creationDate, .posixPermissions, .systemFileNumber, .size] {
  check((after[key] as? NSObject) == (attrs[key] as? NSObject), "personal file metadata or identity changed")
 }
}
print("PASS: read-only personal documents/images outside TestFiles; dedup, transfer, persistence, reference removal, symlink resolution, unsupported-file and atomic-batch rejection; original bytes, inode, timestamps and permissions unchanged")

let trackingDir = temp.appendingPathComponent("tracking-originals")
try fm.createDirectory(at: trackingDir, withIntermediateDirectories: true)
let trackedDoc = trackingDir.appendingPathComponent("before.txt")
try original.write(to: trackedDoc)
try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: trackedDoc.path)
let trackedOriginalAttrs = try fm.attributesOfItem(atPath: trackedDoc.path)
let trackingConfig = temp.appendingPathComponent("tracking-config/zones.json")
let trackingStore = try ReferenceStore(root: samples, config: trackingConfig, allowPersonalFiles: true)
trackingStore.zones = [Zone(title: "A"), Zone(title: "B")]
let ta = trackingStore.zones[0].id, tb = trackingStore.zones[1].id
try trackingStore.add([trackedDoc], to: ta)
try trackingStore.add([trackedDoc], to: tb)
check(trackingStore.zones.allSatisfy { $0.references?[trackedDoc.path] != nil }, "bookmark was not captured")
let sameZoneSnapshot = trackingStore.zones
try trackingStore.transfer(trackedDoc.path, from: ta, to: ta)
check(trackingStore.zones == sameZoneSnapshot, "same-zone drop changed order or tracking metadata")
let renamedDoc = trackingDir.appendingPathComponent("renamed.md")
try fm.moveItem(at: trackedDoc, to: renamedDoc) // TEST ONLY: simulate the user's Finder action.
check(trackingStore.resolvedURL(trackedDoc.path, in: ta)?.path == renamedDoc.path, "action did not resolve a just-renamed file")
check(try trackingStore.refreshReferences(), "rename did not trigger refresh")
check(trackingStore.zones.allSatisfy { $0.paths == [renamedDoc.path] && $0.references?[renamedDoc.path] != nil && $0.references?[trackedDoc.path] == nil }, "rename not synchronized across zones")
check(trackingStore.unavailable.isEmpty, "renamed file marked missing")
let stableConfigAttrs = try fm.attributesOfItem(atPath: trackingConfig.path)
check(try trackingStore.refreshReferences() == false, "unchanged references repeatedly refreshed")
check(try fm.attributesOfItem(atPath: trackingConfig.path)[.modificationDate] as? Date == stableConfigAttrs[.modificationDate] as? Date, "unchanged refresh wrote config")

// Moving the parent directory after saving simulates a move while the app is closed.
let movedDir = temp.appendingPathComponent("moved-originals")
try fm.moveItem(at: trackingDir, to: movedDir)
let movedDoc = movedDir.appendingPathComponent("renamed.md")
let reopened = try ReferenceStore(root: samples, config: trackingConfig, allowPersonalFiles: true)
try reopened.refreshReferences()
check(reopened.zones.allSatisfy { $0.paths == [movedDoc.path] }, "move while closed did not resolve after reopening")
check(try Data(contentsOf: movedDoc) == original, "tracking changed file contents")
let movedAttrs = try fm.attributesOfItem(atPath: movedDoc.path)
for key in [FileAttributeKey.modificationDate, .creationDate, .posixPermissions, .systemFileNumber, .size] {
 check((movedAttrs[key] as? NSObject) == (trackedOriginalAttrs[key] as? NSObject), "tracking modified original identity or metadata")
}

// Keep tracking identity even if the user changes/removes the filename extension.
let oddName = movedDir.appendingPathComponent("renamed-without-extension")
try fm.moveItem(at: movedDoc, to: oddName)
try reopened.transfer(movedDoc.path, from: ta, to: tb)
check(reopened.zones[0].paths.isEmpty && reopened.zones[1].paths.contains(oddName.path), "transfer did not follow a rename before polling")
try reopened.refreshReferences()
check(reopened.zones[1].paths == [oddName.path], "rename created duplicate references")

// A new file at the old path must never replace the bookmarked original.
try Data("unrelated replacement".utf8).write(to: movedDoc)
check(reopened.resolvedURL(oddName.path, in: tb)?.path == oddName.path, "same-name replacement hijacked reference")
let fixtureTrash = temp.appendingPathComponent(".Trash")
try fm.createDirectory(at: fixtureTrash, withIntermediateDirectories: true)
let trashedDoc = fixtureTrash.appendingPathComponent("tracked-document")
try fm.moveItem(at: oddName, to: trashedDoc)
try Data("different file at last known path".utf8).write(to: oddName)
try reopened.refreshReferences()
check(reopened.zones[1].paths == [oddName.path] && reopened.unavailable.contains(oddName.path), "unavailable reference was lost or rebound")
check(reopened.resolvedURL(oddName.path, in: tb) == nil, "action opened an unrelated replacement or trashed file")
let restoredDoc = movedDir.appendingPathComponent("restored.txt")
try fm.moveItem(at: trashedDoc, to: restoredDoc)
try reopened.refreshReferences()
check(reopened.zones[1].paths == [restoredDoc.path] && reopened.unavailable.isEmpty, "unavailable original did not recover")
check(try Data(contentsOf: restoredDoc) == original, "recovery modified the original")

// Legacy path-only JSON gains bookmarks without changing the layout or files.
let legacyConfig = temp.appendingPathComponent("legacy/zones.json")
let legacy = try ReferenceStore(root: samples, config: legacyConfig, allowPersonalFiles: true)
legacy.zones = [Zone(title: "legacy", paths: [restoredDoc.path], x: 51, y: 62, width: 333, height: 222, locked: true)]
try legacy.save()
let migrated = try ReferenceStore(root: samples, config: legacyConfig, allowPersonalFiles: true)
try migrated.refreshReferences()
check(migrated.zones[0].references?[restoredDoc.path] != nil && migrated.zones[0].paths == legacy.zones[0].paths && migrated.zones[0].x == 51 && migrated.zones[0].locked, "legacy migration changed layout or failed tracking")
// Unlock before deliberately removing a reference; locked partitions now reject edits.
migrated.zones[0].locked = false; try migrated.save()
let capturedSnapshot = migrated.zones
let capturedRefresh = ReferenceStore.refreshed(capturedSnapshot, root: samples, allowPersonalFiles: true)
try migrated.remove(restoredDoc.path, from: migrated.zones[0].id)
check(try migrated.applyRefresh(capturedRefresh, basedOn: capturedSnapshot) == false && migrated.zones[0].paths.isEmpty, "stale background refresh resurrected a removed reference")
check(fm.fileExists(atPath: restoredDoc.path), "removing tracked reference deleted original")

let restrictedDoc = samples.appendingPathComponent("restricted.txt")
try original.write(to: restrictedDoc)
let restricted = try ReferenceStore(root: samples, config: temp.appendingPathComponent("restricted-config/zones.json"))
restricted.zones = [Zone(title: "restricted")]
try restricted.add([restrictedDoc], to: restricted.zones[0].id)
let escapedDoc = temp.appendingPathComponent("escaped.txt")
try fm.moveItem(at: restrictedDoc, to: escapedDoc)
try restricted.refreshReferences()
check(restricted.unavailable.contains(restrictedDoc.path) && restricted.resolvedURL(restrictedDoc.path, in: restricted.zones[0].id) == nil, "bookmark bypassed restricted-root mode")

let rollbackParent = temp.appendingPathComponent("refresh-rollback")
let rollbackStore = try ReferenceStore(root: samples, config: rollbackParent.appendingPathComponent("zones.json"), allowPersonalFiles: true)
rollbackStore.zones = [Zone(title: "rollback")]
try rollbackStore.add([restoredDoc], to: rollbackStore.zones[0].id)
let rollbackSnapshot = rollbackStore.zones
let rollbackMoved = movedDir.appendingPathComponent("rollback-moved.txt")
try fm.moveItem(at: restoredDoc, to: rollbackMoved)
try fm.moveItem(at: rollbackParent, to: temp.appendingPathComponent("saved-rollback-config"))
try Data("blocked directory".utf8).write(to: rollbackParent)
do { try rollbackStore.refreshReferences(); fatalError("refresh write unexpectedly succeeded") }
catch { check(rollbackStore.zones == rollbackSnapshot && rollbackStore.unavailable.isEmpty, "refresh save failure did not roll back") }
check(try Data(contentsOf: rollbackMoved) == original, "failed refresh modified original")
print("PASS: bookmarks follow rename, parent-directory move and relaunch; all-zone sync, live action and cross-zone transfer after rename, extension change, duplicate convergence, legacy migration, missing/replaced-file identity protection, recovery, no-op write avoidance, stale-snapshot rejection, root-policy enforcement, atomic refresh rollback; original bytes and metadata preserved")

try testStorageAndGeometry()
