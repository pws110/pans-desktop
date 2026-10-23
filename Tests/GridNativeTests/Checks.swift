// Compiled after the production main.swift declarations, replacing only its bootstrap.
// Direct callbacks against OUR test windows; no system mouse events are sent.
final class LocalDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, point: NSPoint, payload: ReferenceDrag) throws {
        draggingDestinationWindow = window; draggingLocation = point
        super.init()
        draggingPasteboard.setData(try JSONEncoder().encode(payload), forType: NSPasteboard.PasteboardType(referenceType))
    }
    init(window: NSWindow, point: NSPoint, externalURLs: [URL]) {
        draggingDestinationWindow = window; draggingLocation = point
        super.init()
        draggingPasteboard.writeObjects(externalURLs.map { $0 as NSURL })
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { if try !condition() { throw NSError(domain: label, code: 1) }; print("PASS: " + label) }
func pump() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12)) }
let nativeApp = NSApplication.shared
nativeApp.setActivationPolicy(.accessory); nativeApp.finishLaunching()
let state = AppState(), fm = FileManager.default
let nativeRoot = state.home
try fm.createDirectory(at: state.sampleRoot, withIntermediateDirectories: true)
func fixture(_ name: String) throws -> URL { let u = state.sampleRoot.appendingPathComponent(name); try Data(("new native fixture " + name).utf8).write(to: u); return u }
let aFiles = try ["A-文档.txt", "B-文档.txt", "C-文档.txt", "D-文档.txt"].map(fixture)
let bFiles = try ["E-文档.txt", "F-文档.txt"].map(fixture)
let folder = state.sampleRoot.appendingPathComponent("新建目标文件夹")
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
state.store = try ReferenceStore(root: state.sampleRoot, config: nativeRoot.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
state.store.zones = [Zone(title: "网格测试A", paths: aFiles.map(\.path), x: 700,y: 500,width: 330,height: 400), Zone(title: "网格测试B",paths: bFiles.map(\.path) + [folder.path],x: 1050,y: 500,width: 330,height: 400,organizeFiles: false)]
state.store.zones += (0..<4).map { Zone(title: "无关锁定区\($0+1)", locked: true) }
let externalExcel = try fixture("独立锁定-全新Excel.xlsx")
if CommandLine.arguments.count > 1 { try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])).write(to: externalExcel) }
state.store.zones[2].locked = false
try state.store.add([externalExcel], to: state.store.zones[2].id)
state.store.zones[2].locked = true
try state.store.save()
state.storage = try StorageEngine(home: nativeRoot, references: state.store)
state.partitionArchive = try PartitionArchive(url: nativeRoot.appendingPathComponent("Configuration/deleted-partitions.json"))
for z in state.store.zones.prefix(2) { state.makePanel(z) };pump()
let a = state.store.zones[0].id,b = state.store.zones[1].id
let dropA = state.panels[a]!.contentView as! DropContainer,dropB = state.panels[b]!.contentView as! DropContainer
func cell(_ path: String,in drop: DropContainer) throws -> NSRect {
    drop.layoutSubtreeIfNeeded();pump()
    guard let v = state.gridCells.allObjects.first(where: { $0.path == path && $0.zone == drop.zoneID && $0.window === drop.window && !$0.visibleRect.isEmpty }) else { throw NSError(domain: "missing grid probe " + path,code: 1) }
    return drop.convert(v.bounds,from: v)
}
func drag(_ paths: [String],from source: UUID,to drop: DropContainer,over path: String,center: Bool = false,after: Bool = false) throws -> LocalDraggingInfo {
    let r = try cell(path,in: drop)
    let x = center ? r.midX : (after ? r.maxX-3 : r.minX+3)
    let p = drop.convert(NSPoint(x: x,y: r.midY),to: nil)
    return try LocalDraggingInfo(window: drop.window!,point: p,payload: ReferenceDrag(zone: source,path: paths[0],paths: paths,sessionID: UUID()))
}
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
state.lock(b)
let externalCell = try cell(aFiles[0].path, in: dropA)
let rawFinder = LocalDraggingInfo(window: dropA.window!, point: dropA.convert(NSPoint(x: externalCell.minX + 3, y: externalCell.midY), to: nil), externalURLs: [externalExcel])
try require(state.store.zones.filter(\.locked).count == 5 && dropA.proposed(rawFinder) == .move, "raw Finder Excel drop accepted with only one of six partitions unlocked")
try require(dropA.performDragOperation(rawFinder), "raw Finder external-file drop commits through actual destination callback")
let importedExcel = try state.storage.folder(a).appendingPathComponent(externalExcel.lastPathComponent)
try require(state.store.zones[2].paths == [importedExcel.path], "unrelated locked Excel reference retained and updated after native outside drop")
try state.storage.undo();state.revision += 1;pump()
try require(fm.fileExists(atPath: externalExcel.path) && state.store.zones[2].locked && state.zone(a).paths.count == 4, "outside-drop undo does not require unlocking the other five partitions")
state.lock(b)
let d1 = try drag([aFiles[3].path],from:a,to:dropA,over:aFiles[0].path)
try require(dropA.proposed(d1) == .move && dropA.guide.target?.index == 0,"native same-zone destination shows aligned first-slot guide")
if let rep = dropA.bitmapImageRepForCachingDisplay(in: dropA.bounds) { dropA.cacheDisplay(in: dropA.bounds,to:rep);try rep.representation(using:.png,properties:[:])?.write(to:nativeRoot.appendingPathComponent("grid-guide.png")) }
try require(dropA.performDragOperation(d1) && state.zone(a).paths == [aFiles[3].path,aFiles[0].path,aFiles[1].path,aFiles[2].path],"native drop callback reorders same-zone icons")
let payload = try JSONDecoder().decode(ReferenceDrag.self,from:d1.draggingPasteboard.data(forType:NSPasteboard.PasteboardType(referenceType))!)
let tile = ReferenceTileView();tile.app = state;tile.zone = a;tile.path = aFiles[3].path;tile.dragSessionID = payload.sessionID;tile.moveItems = [try FileMoveItem(source:aFiles[3],referenceData:Data())]
tile.finishDrag(at:.zero,operation:.move)
try require(state.zone(a).paths.count == 4 && state.handledDragSessions.isEmpty,"internal reorder completion does not run external export or remove reference")
let d2 = try drag([aFiles[1].path,aFiles[2].path],from:a,to:dropB,over:bFiles[1].path)
try require(dropB.proposed(d2) == .move && dropB.guide.target?.index == 1,"cross-zone native destination selects exact insertion gap")
try require(dropB.performDragOperation(d2) && state.zone(b).paths == [bFiles[0].path,aFiles[1].path,aFiles[2].path,bFiles[1].path,folder.path],"reference-only native cross-zone insert preserves group and original paths")
state.lock(b)
let denied = try drag([aFiles[0].path],from:a,to:dropB,over:bFiles[0].path)
try require(dropB.proposed(denied).isEmpty,"native destination rejects locked target")
state.lock(b);state.lock(a)
try require(dropB.proposed(denied).isEmpty,"native destination rejects locked source")
state.lock(a)
let into = try drag([aFiles[0].path],from:a,to:dropB,over:folder.path,center:true)
try require(dropB.proposed(into) == .move && dropB.guide.target?.folderPath == folder.path,"folder center is a folder drop rather than an insertion gap")
if let rep = dropB.bitmapImageRepForCachingDisplay(in: dropB.bounds) {dropB.cacheDisplay(in: dropB.bounds,to:rep);try rep.representation(using:.png,properties:[:])?.write(to:nativeRoot.appendingPathComponent("folder-guide.png"))}
try require(dropB.performDragOperation(into) && fm.fileExists(atPath:folder.appendingPathComponent(aFiles[0].lastPathComponent).path) && !state.zone(a).paths.contains(aFiles[0].path),"native cross-zone folder callback moves into actual folder")
try state.storage.undo();state.revision += 1;pump()
let sameFolder = try drag([bFiles[0].path],from:b,to:dropB,over:folder.path,center:true)
try require(dropB.proposed(sameFolder) == .move && dropB.performDragOperation(sameFolder) && fm.fileExists(atPath:folder.appendingPathComponent(bFiles[0].lastPathComponent).path),"native same-zone folder drop moves file into folder")
try state.storage.undo();state.revision += 1;pump()
state.change(b) { $0.organizeFiles = true }
let physical = try drag([aFiles[0].path],from:a,to:dropB,over:bFiles[1].path)
try require(dropB.proposed(physical) == .move && dropB.performDragOperation(physical),"native physical cross-zone insertion accepted")
let managed = try state.storage.folder(b).appendingPathComponent(aFiles[0].lastPathComponent)
let wanted = [bFiles[0].path,aFiles[1].path,aFiles[2].path,managed.path,bFiles[1].path,folder.path]
try require(state.zone(b).paths == wanted && !fm.fileExists(atPath:aFiles[0].path),"native physical insertion commits exact grid order and source disappears")
try state.storage.undo();state.revision += 1;pump()
try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == front && state.panels.values.allSatisfy { $0.styleMask.contains(.nonactivatingPanel) && $0.level == state.desktopLevel && !$0.canBecomeMain && !$0.isFloatingPanel },"native callbacks preserve nonactivation and desktop layer")
for p in state.panels.values {p.delegate=nil;p.orderOut(nil)}
print("ALL NATIVE GRID/FOLDER CALLBACK TESTS PASSED; system mouse gesture is separate")
