// AppKit destination/source callbacks and real file moves on new, isolated samples.
// This does not automate a system mouse gesture or operate the production app.
func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !condition() { throw NSError(domain: label, code: 1) }
    print("PASS: " + label)
}
func pump() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12)) }
let nativeApp = NSApplication.shared
nativeApp.setActivationPolicy(.accessory); nativeApp.finishLaunching()
let state = AppState(), fm = FileManager.default
let root = state.home
let desktop = root.appendingPathComponent("FixtureDesktop", isDirectory: true)
try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
try fm.createDirectory(at: state.sampleRoot, withIntermediateDirectories: true)
let txt = desktop.appendingPathComponent("本次新建-文档.txt")
let excel = desktop.appendingPathComponent("本次新建-Excel.xlsx")
let png = desktop.appendingPathComponent("本次新建-图片.png")
let folder = desktop.appendingPathComponent("本次新建-文件夹", isDirectory: true)
try Data("New isolated round-trip document.\n中文测试内容。\n".utf8).write(to: txt)
try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])).write(to: excel)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for y in 0..<16 { for x in 0..<16 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
try bitmap.representation(using: .png, properties: [:])!.write(to: png)
try fm.createDirectory(at: folder.appendingPathComponent("子文件夹"), withIntermediateDirectories: true)
try Data("folder contents preserved\n".utf8).write(to: folder.appendingPathComponent("子文档.txt"))
try Data(contentsOf: png).write(to: folder.appendingPathComponent("子文件夹/子图片.png"))
let samples = [txt, excel, png, folder]
func contents(_ url: URL) throws -> [String: Data] {
    let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    if !directory { return ["file": try Data(contentsOf: url)] }
    var result: [String: Data] = ["/": Data()]
    for case let child as URL in fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])! {
        let name = String(child.path.dropFirst(url.path.count))
        if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { result[name + "/"] = Data() }
        else { result[name] = try Data(contentsOf: child) }
    }
    return result
}
let expected = try Dictionary(uniqueKeysWithValues: samples.map { ($0.lastPathComponent, try contents($0)) })
let identities = try Dictionary(uniqueKeysWithValues: samples.map { ($0.lastPathComponent, try FileIdentity(url: $0)) })
state.store = try ReferenceStore(root: state.sampleRoot, config: root.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
state.store.zones = [Zone(title: "隔离测试-唯一解锁区", x: 100, y: 500, width: 330, height: 400)]
state.store.zones += (1...5).map { Zone(title: "隔离测试-锁定区\($0)", paths: $0 == 1 ? samples.map(\.path) : [], x: 500, y: 500, width: 300, height: 300, locked: true) }
try state.store.save()
state.storage = try StorageEngine(home: root, references: state.store)
state.partitionArchive = try PartitionArchive(url: root.appendingPathComponent("Configuration/deleted-partitions.json"))
let a = state.store.zones[0].id, b = state.store.zones[1].id
let initialGeometry = state.store.zones.map { [$0.x, $0.y, $0.width, $0.height] }
func locksRemain() -> Bool {
    !state.store.zones[0].locked && state.store.zones.dropFirst().allSatisfy(\.locked)
        && state.store.zones.map { [$0.x, $0.y, $0.width, $0.height] } == initialGeometry
}
state.makePanel(state.zone(a)); pump()
let drop = state.panels[a]!.contentView as! DropContainer
func incoming(_ urls: [URL], to target: DropContainer) -> LocalDraggingInfo {
    LocalDraggingInfo(window: target.window!, point: target.convert(NSPoint(x: 18, y: target.bounds.maxY - 90), to: nil), externalURLs: urls)
}
func exportThroughSourceCallback(_ urls: [URL]) throws {
    let payload = try JSONEncoder().encode(ReferenceDrag(zone: a, path: urls[0].path, paths: urls.map(\.path), sessionID: UUID()))
    let items = try urls.map { try FileMoveItem(source: $0, referenceData: payload) }
    let pasteboard = NSPasteboard.withUniqueName()
    try require(pasteboard.writeObjects(items), "native source writes real file URLs for export")
    let finderURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    try require(finderURLs.map(\.path) == urls.map(\.path), "Finder-format export URLs match selected samples")
    // Simulate Finder's move of the received URLs, then invoke production source completion.
    // Both endpoints are confined to this new test home; the real Desktop is untouched.
    for url in finderURLs { try fm.moveItem(at: url, to: desktop.appendingPathComponent(url.lastPathComponent)) }
    let tile = ReferenceTileView(); tile.app = state; tile.zone = a; tile.path = urls[0].path
    tile.moveItems = items; tile.dragSessionID = UUID(); tile.exportsFileMove = true
    tile.finishDrag(at: .zero, operation: .move); pump()
    try require(state.zone(a).paths.isEmpty && state.storage.records.last?.kind == "external-move" && state.storage.records.last?.state == "done", "native drag-out completion removes source membership and journals success")
}
try require(locksRemain(), "exactly one of six test partitions unlocked at start")
for sample in samples {
    let name = sample.lastPathComponent
    let drag = incoming([sample], to: drop)
    try require(drop.proposed(drag) == .move && drop.prepareForDragOperation(drag), "unlocked destination accepts " + name + " while five other partitions remain locked")
    try require(drop.performDragOperation(drag), "native external-drop callback imports " + name)
    let managed = try state.storage.folder(a).appendingPathComponent(name)
    try require(!fm.fileExists(atPath: sample.path) && state.zone(a).paths == [managed.path] && FileIdentity(url: managed) == identities[name] && contents(managed) == expected[name], "import preserves file identity/content/folder tree: " + name)
    try require(locksRemain() && state.zone(b).paths.contains(managed.path), "other five stay locked; unrelated reference follows imported " + name)
    try exportThroughSourceCallback([managed])
    try require(FileIdentity(url: sample) == identities[name] && contents(sample) == expected[name] && !fm.fileExists(atPath: managed.path), "drag-out returns intact sample to isolated desktop: " + name)
    try require(locksRemain() && state.zone(b).paths.contains(sample.path), "other five stay locked after exporting " + name)
    try state.storage.undo(); state.revision += 1; pump()
    try require(fm.fileExists(atPath: managed.path) && state.zone(a).paths == [managed.path] && locksRemain(), "export undo works without unlocking unrelated partitions: " + name)
    try state.storage.undo(); state.revision += 1; pump()
    try require(fm.fileExists(atPath: sample.path) && state.zone(a).paths.isEmpty && locksRemain(), "import undo restores baseline with same independent locks: " + name)
}
let batch = incoming(samples, to: drop)
try require(drop.proposed(batch) == .move && drop.performDragOperation(batch) && state.zone(a).paths.count == 4 && locksRemain(), "mixed document/image/folder batch imports with only one partition unlocked")
let managedBatch = try samples.map { try state.storage.folder(a).appendingPathComponent($0.lastPathComponent) }
try exportThroughSourceCallback(managedBatch)
try require(try samples.allSatisfy { try FileIdentity(url: $0) == identities[$0.lastPathComponent] && contents($0) == expected[$0.lastPathComponent] } && locksRemain(), "mixed batch drag-out preserves all four sample identities and contents")
// Negative control: a locked target must still reject every sample type.
state.makePanel(state.zone(b)); pump()
let lockedDrop = state.panels[b]!.contentView as! DropContainer
for sample in samples {
    let drag = incoming([sample], to: lockedDrop)
    try require(lockedDrop.proposed(drag).isEmpty && !lockedDrop.prepareForDragOperation(drag) && !lockedDrop.performDragOperation(drag) && fm.fileExists(atPath: sample.path) && locksRemain(), "locked target rejects without changing sample: " + sample.lastPathComponent)
}
try require(state.panels.values.allSatisfy { !$0.styleMask.contains(.nonactivatingPanel) && $0.level == state.desktopLevel && $0.canBecomeMain }, "test callbacks retain production desktop window policy")
try require(state.storage.records.allSatisfy { $0.moves.allSatisfy { $0.from.hasPrefix(root.path + "/") && $0.to.hasPrefix(root.path + "/") } }, "all filesystem operations confined to newly created isolated test home")
for panel in state.panels.values { panel.delegate = nil; panel.orderOut(nil) }
print("ALL ONE-UNLOCKED ROUND-TRIP CALLBACK TESTS PASSED; system mouse gesture not automated")
