// AppKit callback tests operate only this new app's own windows and fixtures.
// They do not inject a system pointer gesture or operate the production app.
func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !condition() { throw NSError(domain: label, code: 1) }
    print("PASS: " + label)
}
func rejects(_ label: String, _ work: () throws -> Void) throws {
    do { try work() } catch { print("PASS: " + label); return }
    throw NSError(domain: "unexpected success: " + label, code: 1)
}
func pump() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15)) }
let nativeApp = NSApplication.shared
nativeApp.setActivationPolicy(.accessory); nativeApp.finishLaunching()
let state = AppState(), fm = FileManager.default
let root = state.home
let expectedTestRoot = ProcessInfo.processInfo.environment["PANS_DESKTOP_QA_ROOT"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }
try require(expectedTestRoot == root.resolvingSymlinksInPath().standardizedFileURL, "isolated data home confirmed before writing")
try fm.createDirectory(at: state.sampleRoot, withIntermediateDirectories: true)
let doc = state.sampleRoot.appendingPathComponent("新建文档-" + UUID().uuidString + ".txt")
let png = state.sampleRoot.appendingPathComponent("新建图片.png")
let folder = state.sampleRoot.appendingPathComponent("新建文件夹")
try Data("Only a new test document.\n".utf8).write(to: doc)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<8 { for x in 0..<8 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), atX: x, y: y) } }
try bitmap.representation(using: .png, properties: [:])!.write(to: png)
try fm.createDirectory(at: folder.appendingPathComponent("子文件夹"), withIntermediateDirectories: true)
try Data("new child".utf8).write(to: folder.appendingPathComponent("子文档.txt"))
try Data(contentsOf: png).write(to: folder.appendingPathComponent("子文件夹/子图片.png"))
func contents(_ url: URL) throws -> [String: Data] {
    if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true { return ["file": try Data(contentsOf: url)] }
    var result: [String: Data] = [:]
    for case let child as URL in fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])! {
        let name = String(child.path.dropFirst(url.path.count))
        result[name] = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? Data() : Data(contentsOf: child)
    }
    return result
}
let samples = [doc, png, folder]
let originals = try samples.map { try contents($0) }
let identities = try samples.map { try FileIdentity(url: $0) }
state.store = try ReferenceStore(root: state.sampleRoot, config: root.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
state.store.zones = [Zone(title: "唯一解锁测试区", x: 100, y: 300, width: 500, height: 400, organizeFiles: false)]
state.store.zones += (1...5).map { Zone(title: "锁定测试区\($0)", locked: true, organizeFiles: false) }
let a = state.store.zones[0].id, b = state.store.zones[1].id
try state.store.add(samples, to: a)
state.store.zones[1].locked = false; try state.store.add([doc], to: b); state.store.zones[1].locked = true; try state.store.save()
state.storage = try StorageEngine(home: root, references: state.store)
state.partitionArchive = try PartitionArchive(url: root.appendingPathComponent("Configuration/deleted-partitions.json"))
state.revealDesktopTestHook = {}
let engine = state.fileActions
func preserved() throws -> Bool {
    try samples.enumerated().allSatisfy { try contents($0.element) == originals[$0.offset] && FileIdentity(url: $0.element) == identities[$0.offset] }
}
let pb = NSPasteboard.withUniqueName()
try engine.copyToPasteboard(samples.map(\.path), in: a, pasteboard: pb)
let copiedURLs = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
try require(copiedURLs.map(\.path) == samples.map(\.path) && preserved(), "Copy exports all selected URLs, preserving originals")
let copies = try engine.duplicate(samples.map(\.path), in: a)
try require(copies.count == 3 && copies.enumerated().allSatisfy { try contents($0.element) == originals[$0.offset] } && preserved(), "Duplicate preserves document/image/folder bytes and creates tracked copies")
let copies2 = try engine.duplicate([doc.path], in: a)
try require(copies2[0] != copies[0] && fm.fileExists(atPath: copies[0].path), "Duplicate never overwrites an existing copy")
let aliases = try engine.alias(samples.map(\.path), in: a)
try require(aliases.enumerated().allSatisfy { try URL(resolvingAliasFileAt: $0.element).path == samples[$0.offset].path } && preserved(), "Aliases resolve to the correct intact originals")
let archive = try engine.compress(samples.map(\.path), in: a)
let unpacked = root.appendingPathComponent("Unpacked")
let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); zip.arguments = ["-x", "-k", archive.path, unpacked.path]
try zip.run(); zip.waitUntilExit()
try require(zip.terminationStatus == 0 && samples.enumerated().allSatisfy { try contents(unpacked.appendingPathComponent("Archive/" + $0.element.lastPathComponent)) == originals[$0.offset] } && preserved(), "ZIP restores selected Unicode document/image/folder contents intact")
try engine.tags(["Pan Test Tag"], color: 6, paths: [doc.path], in: a)
let tags = try doc.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
try require(tags.tagNames?.contains("Pan Test Tag") == true && tags.labelNumber == 6 && preserved(), "Finder tags/colors update metadata without modifying contents or identity")
try state.storage.renameFile(doc, name: "测试重命名.txt", sourceZone: a)
let renamed = doc.deletingLastPathComponent().appendingPathComponent("测试重命名.txt")
try require(state.zone(a).paths.contains(renamed.path) && state.zone(b).paths == [renamed.path] && state.zone(b).locked && !fm.fileExists(atPath: doc.path), "Rename updates own and locked sibling references independently")
try state.storage.undo()
try require(preserved() && state.zone(a).paths.contains(doc.path) && state.zone(b).paths == [doc.path], "Rename undo restores original name, references, identity, and contents")
try rejects("Rename refuses to overwrite a different file") { _ = try state.storage.renameFile(doc, name: png.lastPathComponent, sourceZone: a) }
state.lock(a)
let pbBefore = pb.changeCount
try rejects("Locked source blocks Copy") { try engine.copyToPasteboard([doc.path], in: a, pasteboard: pb) }
try require(pb.changeCount == pbBefore, "Rejected Copy leaves the clipboard untouched")
try rejects("Locked source blocks Duplicate") { _ = try engine.duplicate([doc.path], in: a) }
try rejects("Locked source blocks Rename") { _ = try state.storage.renameFile(doc, name: "no.txt", sourceZone: a) }
try rejects("Locked source blocks tags") { try engine.tags([], paths: [doc.path], in: a) }
try rejects("Locked source blocks Trash drag") { try engine.finishTrashDrag([FileMoveItem(source: doc, referenceData: Data())], in: a) }
try require(preserved() && state.store.zones.allSatisfy(\.locked), "all rejected operations preserve every fixture")
state.lock(a)
// Real system Trash calls, followed by exact journal undo. Never empty Trash.
for source in samples {
    let item = try FileMoveItem(source: source, referenceData: Data())
    try engine.finishTrashDrag([item], in: a)
    let record = state.storage.records.last!
    try require(!fm.fileExists(atPath: source.path) && !state.zone(a).paths.contains(source.path) && record.kind == "trash" && record.state == "done", "Direct Trash completion removes only new fixture and source reference: " + source.lastPathComponent)
    let destination = URL(fileURLWithPath: record.moves[0].to)
    try require(destination.pathComponents.contains(".Trash") && contents(destination) == originals[samples.firstIndex(of: source)!], "real Trash destination contains intact fixture")
    try state.storage.undo()
    try require(preserved() && state.zone(a).paths.contains(source.path) && state.store.zones.dropFirst().allSatisfy(\.locked), "Trash undo restores fixture without unlocking other partitions")
}
// Finder may complete the physical Trash move before notifying the drag source.
let item = try FileMoveItem(source: doc, referenceData: Data())
let trashed = try StorageEngine.recycle(doc)
do {
    try engine.finishTrashDrag([item], in: a)
    try require(!state.zone(a).paths.contains(doc.path) && state.storage.records.last?.moves.first?.to == trashed.path, "already-trashed callback verifies identity and records Trash location")
    try state.storage.undo()
} catch {
    if fm.fileExists(atPath: trashed.path) && !fm.fileExists(atPath: doc.path) { try StorageEngine.atomicMove(trashed, doc) }
    throw error
}
try require(preserved(), "all real Trash samples restored; no test leftovers in Trash")
var tracker = TileClickTracker()
try require(!tracker.released(key: "a", time: 1, point: .zero, systemClicks: 1) && tracker.released(key: "a", time: 1.6, point: CGPoint(x: 12, y: 9), systemClicks: 1), "generous double-click timing and position tolerance")
try require(!tracker.released(key: "a", time: 2, point: .zero, systemClicks: 1) && !tracker.released(key: "b", time: 2.1, point: .zero, systemClicks: 2), "OS click count cannot open a different file by mistake")
try require(!tracker.released(key: "b", time: 2.2, point: .zero, systemClicks: 2, modifiers: .command), "multi-selection modifier never opens a document")
try require(DesktopRevealPolicy.shouldHide(bundle: "test.document", regular: true, ownPID: 1, pid: 2, hidden: false), "desktop reveal targets visible regular apps")
try require(DesktopRevealPolicy.shouldHide(bundle: "com.apple.finder", regular: true, ownPID: 1, pid: 2, hidden: false) && !DesktopRevealPolicy.shouldHide(bundle: "remote.agent", regular: false, ownPID: 1, pid: 2, hidden: false) && !DesktopRevealPolicy.shouldHide(bundle: "own", regular: true, ownPID: 1, pid: 1, hidden: false), "desktop reveal includes Finder while excluding background agents and itself")
state.makePanel(state.zone(a)); pump()
let panel = state.panels[a]!, drop = panel.contentView as! DropContainer
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
guard let lockControl = descendants(drop).compactMap({ $0 as? HeaderLockControl }).first else { throw NSError(domain: "missing top-right lock", code: 1) }
try require(abs(lockControl.bounds.width - 34) < 0.1 && abs(lockControl.bounds.height - 34) < 0.1, "native lock hover box matches other 34-point header controls")
for point in [NSPoint(x: 1, y: 17), NSPoint(x: 33, y: 17), NSPoint(x: 17, y: 1), NSPoint(x: 17, y: 33)] {
    try require(lockControl.hitTest(lockControl.convert(point, to: lockControl.superview)) === lockControl, "entire 34-point lock background accepts clicks")
}
func lockBitmap(_ name: String) throws -> NSBitmapImageRep {
    pump(); drop.displayIfNeeded()
    let rep = drop.bitmapImageRepForCachingDisplay(in: drop.bounds)!
    drop.cacheDisplay(in: drop.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    return rep
}
let beforeHover = try lockBitmap("lock-normal")
let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 5, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
lockControl.mouseEntered(with: hoverEvent)
let duringHover = try lockBitmap("lock-hover")
try require(lockControl.isHovered && beforeHover.representation(using: .png, properties: [:]) != duringHover.representation(using: .png, properties: [:]), "hover renders a visible gray-white rounded background")
lockControl.mouseExited(with: hoverEvent)
try require(!lockControl.isHovered, "hover background clears on pointer exit")
let otherZones = state.store.zones.dropFirst().map { $0 }
lockControl.performClick(nil); pump()
try require(state.zone(a).locked && Array(state.store.zones.dropFirst()) == otherZones, "top-right lock locks only its own partition")
lockControl.performClick(nil); pump()
try require(!state.zone(a).locked && Array(state.store.zones.dropFirst()) == otherZones, "same top-right button unlocks independently")
func tileFor(_ path: String) throws -> ReferenceTileView {
    panel.contentView?.layoutSubtreeIfNeeded(); pump()
    guard let tile = state.tileViews.allObjects.first(where: { $0.path == path && $0.zone == a && $0.window === panel && !$0.visibleRect.isEmpty }) else { throw NSError(domain: "missing visible tile", code: 1) }
    return tile
}
let tile = try tileFor(doc.path)
for point in [NSPoint(x: 2, y: tile.bounds.midY), NSPoint(x: tile.bounds.maxX - 2, y: tile.bounds.midY), NSPoint(x: tile.bounds.midX, y: tile.bounds.height - 2), NSPoint(x: 2, y: 3)] {
    try require(tile.hitTest(tile.convert(point, to: tile.superview)) === tile, "file card whitespace hit area is active")
}
func event(_ type: NSEvent.EventType, tile: ReferenceTileView, x: CGFloat = 4, y: CGFloat = 60, time: TimeInterval, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: tile.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: time, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
}
var opened: [URL] = []; state.openReferenceTestHook = { url, _ in opened.append(url) }
for locked in [false, true] {
    if state.zone(a).locked != locked { state.lock(a); pump() }
    let v = try tileFor(doc.path)
    v.mouseDown(with: event(.leftMouseDown, tile: v, time: 10))
    v.mouseDragged(with: event(.leftMouseDragged, tile: v, x: 7, y: 62, time: 10.05))
    v.mouseUp(with: event(.leftMouseUp, tile: v, time: 10.1))
    v.mouseDown(with: event(.leftMouseDown, tile: v, time: 10.5, clicks: 2))
    v.mouseUp(with: event(.leftMouseUp, tile: v, time: 10.6, clicks: 2))
    try require(opened.count == (locked ? 2 : 1) && opened.last == doc && !v.dragging, "whole-card double click opens once despite small jitter, locked=" + String(locked))
    let menu = v.makeFileMenu()!
    let operations = Set(menu.items.compactMap { $0.representedObject as? String })
    try require(operations.contains("open") && operations.contains("info") && operations.contains("preview"), "open/preview/info remain available independently of lock state")
    try require(operations.contains("copy") != locked && operations.contains("trash") != locked && operations.contains("rename") != locked && operations.contains("duplicate") != locked, "mutating file menu entries obey only source partition lock")
}
let lockedFrame = panel.frame
let dragTitle = TitleDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 40)); dragTitle.app = state; dragTitle.id = a
panel.contentView!.addSubview(dragTitle)
dragTitle.mouseDown(with: event(.leftMouseDown, tile: tile, time: 30)); dragTitle.mouseDragged(with: event(.leftMouseDragged, tile: tile, x: 80, y: 90, time: 30.2))
try require(panel.frame == lockedFrame && !dragTitle.gestureStarted, "locked partition remains immovable")
dragTitle.removeFromSuperview()
var reveals = 0; state.revealDesktopTestHook = { reveals += 1 }
// Direct dispatch within this test panel, without posting global input.
panel.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 16, y: 30), modifierFlags: [], timestamp: 40, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!)
try require(reveals == 1, "locked partition blank click requests desktop reveal")
try require(panel.level == state.desktopLevel && panel.canBecomeMain, "controls retain desktop level and allow click focus")
state.lock(a)
let trashSample = copies2[0]
let trashTile = ReferenceTileView(); trashTile.app = state; trashTile.zone = a; trashTile.path = trashSample.path
trashTile.moveItems = [try FileMoveItem(source: trashSample, referenceData: Data())]; trashTile.dragSessionID = UUID()
trashTile.finishDrag(at: .zero, operation: .delete)
try require(!fm.fileExists(atPath: trashSample.path) && !state.zone(a).paths.contains(trashSample.path), "production drag-source delete callback routes directly to real Trash")
try state.storage.undo()
try require(fm.fileExists(atPath: trashSample.path) && state.zone(a).paths.contains(trashSample.path), "drag-source Trash callback can restore its new test copy")
let moveToTrashItem = try FileMoveItem(source: trashSample, referenceData: Data())
let moveTrashURL = try StorageEngine.recycle(trashSample)
state.finishNativeMove(moveToTrashItem, sourceZone: a, attempts: 0)
try require(!state.zone(a).paths.contains(trashSample.path) && state.storage.records.last?.kind == "trash" && state.storage.records.last?.moves.first?.to == moveTrashURL.path, "Finder .move-to-Trash completion is also reconciled immediately")
try state.storage.undo()
try require(fm.fileExists(atPath: trashSample.path), ".move-to-Trash completion can restore its exact sample")
try require(preserved(), "all fixture originals retain exact contents and identity at completion")
for p in state.panels.values { p.delegate = nil; p.orderOut(nil) }
print("ALL FILE ACTIONS AND NATIVE CALLBACK TESTS PASSED; physical Dock gesture is a separate UI check")
