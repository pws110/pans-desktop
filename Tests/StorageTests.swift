import Foundation

func testStorageAndGeometry() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("clearzones-storage-" + UUID().uuidString).resolvingSymlinksInPath()
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let bytes = Data("original contents must remain intact".utf8)
    func environment(_ name: String) throws -> (URL, ReferenceStore) {
        let home = base.appendingPathComponent(name)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try ReferenceStore(root: home.appendingPathComponent("samples"), config: home.appendingPathComponent("references-config/zones.json"), allowPersonalFiles: true)
        store.zones = [Zone(title: "常用文件"), Zone(title: "图片素材"), Zone(title: "临时文件"), Zone(title: "待处理")]
        try store.save()
        return (home, store)
    }
    func file(_ home: URL, _ name: String = "original.txt") throws -> URL {
        let url = home.appendingPathComponent("Desktop/" + name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url); try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }
    func unchanged(_ url: URL, _ attrs: [FileAttributeKey: Any]) throws {
        check(try Data(contentsOf: url) == bytes, "storage altered bytes")
        let now = try fm.attributesOfItem(atPath: url.path)
        for key in [FileAttributeKey.systemFileNumber, .size, .creationDate, .modificationDate, .posixPermissions] {
            check((attrs[key] as? NSObject) == (now[key] as? NSObject), "storage changed file identity or metadata")
        }
    }
    let (home, refs) = try environment("normal")
    let original = try file(home), attrs = try fm.attributesOfItem(atPath: original.path)
    let engine = try StorageEngine(home: home, references: refs)
    let a = refs.zones[0].id, b = refs.zones[1].id
    check(fm.fileExists(atPath: original.path), "startup moved a file")
    try engine.collect([original, original], to: a)
    let aFile = try engine.folder(a).appendingPathComponent(original.lastPathComponent)
    check(!fm.fileExists(atPath: original.path) && refs.zones[0].paths == [aFile.path], "collect left the desktop original or lost membership")
    check(engine.records.count == 1 && engine.records[0].state == "done", "journal not completed")
    try unchanged(aFile, attrs)
    try engine.collect([aFile], to: b)
    let bFile = try engine.folder(b).appendingPathComponent(original.lastPathComponent)
    check(!fm.fileExists(atPath: aFile.path) && fm.fileExists(atPath: bFile.path) && refs.zones[0].paths.isEmpty && refs.zones[1].paths == [bFile.path], "physical cross-zone move failed")
    try unchanged(bFile, attrs)
    try engine.undo()
    check(fm.fileExists(atPath: aFile.path) && refs.zones[0].paths == [aFile.path] && refs.zones[1].paths.isEmpty, "cross-zone undo failed")
    try engine.returnToOriginal(aFile)
    check(fm.fileExists(atPath: original.path) && refs.zones.allSatisfy { $0.paths.isEmpty }, "return to original failed")
    try unchanged(original, attrs)
    try engine.undo()
    check(fm.fileExists(atPath: aFile.path), "undo return failed")
    try engine.undo()
    check(fm.fileExists(atPath: original.path) && refs.zones.allSatisfy { $0.paths.isEmpty } && engine.undoRecord == nil, "undo collect failed")
    try unchanged(original, attrs)

    // Removing a managed reference does not remove its file; re-adding it is a no-op on disk.
    try engine.collect([original], to: a)
    try refs.remove(aFile.path, from: a)
    try engine.collect([aFile], to: a)
    check(refs.zones[0].paths == [aFile.path], "managed file could not be re-added")
    try unchanged(aFile, attrs)
    try engine.undo()
    check(refs.zones[0].paths.isEmpty && fm.fileExists(atPath: aFile.path), "undo re-add moved a file")
    try engine.undo()
    check(fm.fileExists(atPath: original.path), "undo collect after re-add failed")

    let pngFile = home.appendingPathComponent("Desktop/image.png")
    let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7V8AAAAASUVORK5CYII=")!
    try pngBytes.write(to: pngFile)
    let pngIdentity = try FileIdentity(url: pngFile)
    try engine.collect([pngFile], to: b)
    let pngStored = try engine.folder(b).appendingPathComponent("image.png")
    check(try (!fm.fileExists(atPath: pngFile.path) && Data(contentsOf: pngStored) == pngBytes && FileIdentity(url: pngStored) == pngIdentity), "image storage failed")
    try engine.undo()
    check(try (Data(contentsOf: pngFile) == pngBytes && FileIdentity(url: pngFile) == pngIdentity), "image undo changed original")

    // A same-name destination and a broken symlink must never be overwritten.
    try bytes.write(to: aFile)
    do { try engine.collect([original], to: a); fatalError("collision accepted") } catch StorageError.collision { }
    check(try (fm.fileExists(atPath: original.path) && Data(contentsOf: aFile) == bytes), "collision changed a file")
    try fm.removeItem(at: aFile)
    try fm.createSymbolicLink(at: aFile, withDestinationURL: home.appendingPathComponent("does-not-exist"))
    do { try engine.collect([original], to: a); fatalError("broken symlink overwritten") } catch StorageError.collision { }
    try fm.removeItem(at: aFile)
    let sameName = try file(home, "other/original.txt")
    do { try engine.collect([original, sameName], to: a); fatalError("duplicate destination batch accepted") } catch StorageError.collision { }
    check(fm.fileExists(atPath: original.path) && fm.fileExists(atPath: sameName.path), "batch preflight moved files")
    let symlink = home.appendingPathComponent("Desktop/link.txt")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: original)
    let script = try file(home, "script.sh")
    let fakeDoc = home.appendingPathComponent("Desktop/fake.app")
    try fm.createDirectory(at: fakeDoc, withIntermediateDirectories: true)
    for forbidden in [symlink, script, fakeDoc] {
        do { try engine.validateImport(forbidden); fatalError("unsafe import accepted") } catch { }
    }

    let (crossHome, crossRefs) = try environment("cross-volume")
    let crossFile = try file(crossHome)
    let crossRoot = crossHome.appendingPathComponent("收纳文件").path
    let crossEngine = try StorageEngine(home: crossHome, references: crossRefs, device: { $0.path.hasPrefix(crossRoot) ? 2 : 1 })
    do { try crossEngine.collect([crossFile], to: crossRefs.zones[0].id); fatalError("cross-volume accepted") } catch StorageError.crossVolume { }
    check(fm.fileExists(atPath: crossFile.path), "cross-volume preflight moved file")

    let (writeHome, writeRefs) = try environment("write-fail")
    let writeFile = try file(writeHome)
    var failWrite = false
    let writeEngine = try StorageEngine(home: writeHome, references: writeRefs, writer: { data, url in
        if failWrite { throw StorageError.journal }; try data.write(to: url, options: .atomic)
    })
    failWrite = true
    do { try writeEngine.collect([writeFile], to: writeRefs.zones[0].id); fatalError("unrecorded move happened") } catch { }
    check(fm.fileExists(atPath: writeFile.path) && writeEngine.records.isEmpty, "intent write failure moved original")

    let (batchHome, batchRefs) = try environment("batch-fail")
    let batchA = try file(batchHome, "a.txt"), batchB = try file(batchHome, "b.txt")
    var moveCount = 0
    let batchEngine = try StorageEngine(home: batchHome, references: batchRefs, mover: { from, to in
        moveCount += 1
        if moveCount == 2 { throw StorageError.failed("injected second move failure") }
        try StorageEngine.atomicMove(from, to)
    })
    try batchEngine.collect([] as [URL], to: batchRefs.zones[0].id)
    do { try batchEngine.collect([batchA, batchB], to: batchRefs.zones[0].id); fatalError("batch failure not raised") } catch { }
    check(fm.fileExists(atPath: batchA.path) && fm.fileExists(atPath: batchB.path) && batchEngine.records.last?.state == "cancelled" && batchRefs.zones.allSatisfy { $0.paths.isEmpty }, "batch rollback lost a file or changed references")

    let (finalHome, finalRefs) = try environment("final-write-fail")
    let finalFile = try file(finalHome)
    var failFinal = true
    let finalEngine = try StorageEngine(home: finalHome, references: finalRefs, writer: { data, url in
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = json["records"] as? [[String: Any]]
        if failFinal && rows?.last?["state"] as? String == "done" { failFinal = false; throw StorageError.journal }
        try data.write(to: url, options: .atomic)
    })
    do { try finalEngine.collect([finalFile], to: finalRefs.zones[0].id); fatalError("final journal failure not raised") } catch { }
    check(fm.fileExists(atPath: finalFile.path) && finalRefs.zones.allSatisfy { $0.paths.isEmpty } && finalEngine.records.last?.state == "cancelled", "final journal failure did not roll back")

    // A failure plus an occupied rollback path preserves both files for inspection.
    let (partialHome, partialRefs) = try environment("partial-rollback")
    let partialA = try file(partialHome, "a.txt"), partialB = try file(partialHome, "b.txt")
    var partialCount = 0
    let partialEngine = try StorageEngine(home: partialHome, references: partialRefs, mover: { from, to in
        partialCount += 1
        if partialCount == 2 { try Data("do not overwrite me".utf8).write(to: partialA); throw StorageError.failed("blocked rollback") }
        try StorageEngine.atomicMove(from, to)
    })
    do { try partialEngine.collect([partialA, partialB], to: partialRefs.zones[0].id); fatalError("partial failure not raised") } catch { }
    let preserved = try partialEngine.folder(partialRefs.zones[0].id).appendingPathComponent("a.txt")
    check(try (Data(contentsOf: partialA) == Data("do not overwrite me".utf8) && Data(contentsOf: preserved) == bytes && fm.fileExists(atPath: partialB.path) && partialEngine.records.last?.state == "attention"), "partial rollback overwrote or lost a file")

    // Simulate a crash after a persisted intent and physical rename; restart observes only.
    let (recoveryHome, recoveryRefs) = try environment("recover-done")
    let recoveryFile = try file(recoveryHome)
    let recoveryEngine = try StorageEngine(home: recoveryHome, references: recoveryRefs)
    let recoveryZone = recoveryRefs.zones[0].id
    let target = try recoveryEngine.folder(recoveryZone).appendingPathComponent("original.txt")
    let planned = try recoveryEngine.plan(recoveryFile, target, after: [Membership(zone: recoveryZone, index: 0)])
    var recoveredJournal = recoveryEngine.journal
    recoveredJournal.records.append(StorageRecord(title: "crash fixture", kind: "collect", moves: [planned]))
    try JSONEncoder().encode(recoveredJournal).write(to: recoveryEngine.journalURL, options: .atomic)
    try StorageEngine.atomicMove(recoveryFile, target)
    let restarted = try StorageEngine(home: recoveryHome, references: recoveryRefs)
    check(restarted.records.last?.state == "done" && recoveryRefs.zones[0].paths == [target.path] && fm.fileExists(atPath: target.path), "startup recovery failed")
    try restarted.undo()
    check(fm.fileExists(atPath: recoveryFile.path), "recovered operation not undoable")

    // Existing references stay in place when storage support is enabled.
    let (legacyHome, legacyRefs) = try environment("existing-reference")
    let legacyFile = try file(legacyHome)
    legacyRefs.zones[0].organizeFiles = false
    try legacyRefs.add([legacyFile], to: legacyRefs.zones[0].id)
    _ = try StorageEngine(home: legacyHome, references: legacyRefs)
    check(fm.fileExists(atPath: legacyFile.path) && legacyRefs.zones[0].paths == [legacyFile.path], "legacy reference was auto-collected")

    var zone = Zone(title: "geometry", x: -400, y: 500, width: 320, height: 280)
    let start = zone.frameValue, screen = ZoneFrame(x: -1920, y: 38, width: 1920, height: 1010)
    zone.toggleMaximum(on: screen, itemCount: 300)
    check(zone.frameValue == screen && zone.isMaximized && zone.restoreFrame == start, "maximize did not use visible screen frame")
    zone.toggleMaximum(on: screen)
    check(zone.frameValue == start && !zone.isMaximized, "restore did not preserve exact geometry")
    zone.toggleCollapsed()
    check(zone.height == 48 && zone.y + zone.height == start.y + start.height, "collapse moved the top edge")
    zone.toggleCollapsed(); check(zone.frameValue == start, "expand did not restore geometry")
    zone.toggleCollapsed(); zone.toggleMaximum(on: screen, itemCount: 300); zone.toggleMaximum(on: screen)
    check(zone.frameValue == start && !zone.isCollapsed, "maximize from collapsed did not restore expanded geometry")
    for count in 0...2 {
        zone.toggleMaximum(on: screen, itemCount: count)
        check(zone.frameValue == start && !zone.isMaximized, "one or two files caused unnecessary expansion")
    }
    var lastArea = 0.0
    for count in [4, 12, 24, 48, 96, 300] {
        let expanded = zone.contentFrame(on: screen, itemCount: count)
        let area = expanded.width * expanded.height
        check(area >= lastArea && expanded.width >= start.width && expanded.height >= start.height, "content growth was not proportional and monotonic")
        check(expanded.x >= screen.x && expanded.y >= screen.y && expanded.x + expanded.width <= screen.x + screen.width && expanded.y + expanded.height <= screen.y + screen.height, "expanded zone escaped visible screen")
        if count <= 48 {
            check(expanded.x > screen.x && expanded.x + expanded.width == start.x + start.width, "small expansion jumped to the left edge instead of retaining right anchor")
            check(expanded.y + expanded.height == start.y + start.height, "small expansion lost top anchor")
        }
        zone.toggleMaximum(on: screen, itemCount: count); zone.toggleMaximum(on: screen)
        check(zone.frameValue == start && !zone.isMaximized, "adaptive expand did not restore original position")
        lastArea = area
    }
    let left = Zone(title: "left", x: -1900, y: 500, width: 300, height: 280)
    check(left.contentFrame(on: screen, itemCount: 12).x == left.x, "left-side zone did not expand from its original left edge")
    print("PASS: real single-copy collect, physical cross-zone transfer, undo stack and return, same-name and broken-symlink protection, unsafe-file refusal, cross-volume preflight, intent/final-journal failures, batch rollback, partial recovery preserves files, crash observation and undo, legacy reference preservation; exact maximize/restore and collapse geometry")
}
