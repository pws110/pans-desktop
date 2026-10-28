// Isolated AppKit rendering and callback tests. No external app is hidden or
// opened, and no system pointer events or personal files are used.
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("FAIL: " + message) }
    print("PASS: " + message)
}
func pump() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
let root = Bundle.main.bundleURL.deletingLastPathComponent()
freopen(root.appendingPathComponent("results.log").path, "w", stdout)
setbuf(stdout, nil)
let nativeApp = NSApplication.shared
nativeApp.setActivationPolicy(.accessory)
nativeApp.finishLaunching()
let state = AppState()
let fixtures = root.appendingPathComponent("fixtures")
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
let names = ["客户资料.txt", "会议纪要.txt", "产品图片.txt", "采购合同.txt", "美国站广告销售与库存汇总分析报告最终确认版本.xlsx", "发票资料.txt", "设计资料.txt", "库存记录.txt", "工作安排.txt"]
let files = try names.map { name -> URL in
    let url = fixtures.appendingPathComponent(name)
    try Data(("Isolated test: " + name).utf8).write(to: url)
    return url
}
let bytesBefore = try files.map { try Data(contentsOf: $0) }
state.store = try ReferenceStore(root: fixtures, config: root.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
state.store.zones = [Zone(title: "透明悬停验收", paths: files.map(\.path), width: 330, height: 420, locked: true, organizeFiles: false)]
try state.store.save()
let referencePathsBefore = state.store.zones.map(\.paths)
state.storage = try StorageEngine(home: root, references: state.store)
state.partitionArchive = try PartitionArchive(url: root.appendingPathComponent("Configuration/deleted-partitions.json"))
for file in files { state.imageCache[file.path] = NSWorkspace.shared.icon(forFile: file.path); state.sizeCache[file.path] = "测试" }
let id = state.store.zones[0].id
let screen = NSScreen.main!.visibleFrame
let window = ZonePanel(contentRect: NSRect(x: screen.midX - 165, y: screen.midY - 210, width: 330, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.hidesOnDeactivate = false
window.controller = state
let host = NSHostingView(rootView: ZoneView(app: state, id: id))
window.contentView = host
state.panels[id] = window
window.orderFront(nil)
func snapshot(_ name: String) throws {
    pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
try snapshot("before-hover")
let tiles = state.tileViews.allObjects.filter { $0.window === window }
require(tiles.count == 9, "nine fixture tiles render in three equal rows")
let owner = tiles.first { $0.path == files[4].path }!
let below = tiles.first { $0.path == files[7].path }!
let frames = Dictionary(uniqueKeysWithValues: tiles.map { ($0.path, $0.frame) })
func tileRect(_ tile: ReferenceTileView) -> NSRect { window.convertToScreen(tile.convert(tile.bounds, to: nil)) }
let ordered = files.map { file in tiles.first { $0.path == file.path }! }
let rects = ordered.map(tileRect)
require(rects.allSatisfy { abs($0.width - 81) < 0.01 && abs($0.height - 81) < 0.01 }, "all cells are square without a reserved metadata row")
require(abs(rects[1].minX - rects[0].minX - 84) < 0.01 && abs(rects[2].minX - rects[1].minX - 84) < 0.01, "horizontal cell gap is halved from 6 to 3 points")
require(abs(rects[0].minY - rects[3].minY - 84) < 0.01 && abs(rects[3].minY - rects[6].minY - 84) < 0.01, "both vertical row gaps equal the horizontal gap")
func tilePixels(_ tile: ReferenceTileView) -> Data {
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let rect = tile.convert(tile.bounds, to: host)
    let bitmap = host.bitmapImageRepForCachingDisplay(in: rect)!
    host.cacheDisplay(in: rect, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])!
}
let neighborPixels = Dictionary(uniqueKeysWithValues: tiles.filter { $0 !== owner }.map { ($0.path, tilePixels($0)) })
state.showHover(owner)
try snapshot("during-hover")
require(state.hoveredFile?.path == owner.path, "hover selects the requested complete name")
require(state.hoverPanel?.backgroundColor == .clear && state.hoverPanel?.isOpaque == false && state.hoverPanel?.hasShadow == false, "preview background and shadow are transparent")
require(state.hoverPanel?.ignoresMouseEvents == true, "preview preserves pointer access to file tiles")
require(state.hoverPanel!.level.rawValue > window.level.rawValue, "full name renders above sibling files")
require(tiles.filter { $0 !== owner }.allSatisfy { tilePixels($0) == neighborPixels[$0.path] }, "upper, lower and side neighbors remain pixel-identical and visible")
require(tiles.allSatisfy { $0.frame == frames[$0.path] && $0.window === window }, "hover preserves all tile positions and native targets")
func verifyText(_ view: FullNameHoverView, name: String) throws {
    require(abs(view.titleRect.width - view.iconSize.width) < 0.01, "icon and name column have equal widths: " + name)
    let textStorage = NSTextStorage(attributedString: view.title)
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: view.titleRect.size)
    container.lineFragmentPadding = 0
    textStorage.addLayoutManager(layout); layout.addTextContainer(container)
    let glyphs = layout.glyphRange(for: container)
    let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    require(chars.length == (view.name as NSString).length, "all characters and extension fit: " + name)
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    require(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01, "outside lettering and icon remains transparent: " + name)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
let preview = state.hoverPanel!.contentView as! FullNameHoverView
require(preview.name == names[4] && preview.titleRect.height > 29, "long name wraps downward without truncation")
require(abs(preview.iconSize.width - FullNameHoverView.baseIconSize.width) < 0.01, "ordinary long names preserve the 1.3x icon width")
try verifyText(preview, name: "long-name")
let maximum = FullNameHoverView(name: String(repeating: "W", count: 251) + ".pdf", icon: state.imageCache[owner.path]!, availableSize: screen.insetBy(dx: 8, dy: 8).size)
try verifyText(maximum, name: "maximum-name")
require(maximum.frame.height <= screen.height - 16 && maximum.frame.width <= screen.width - 16, "maximum-length filename fits this screen at enlarged text size")
let overlap = state.hoverPanel!.frame.intersection(tileRect(below))
require(!overlap.isEmpty, "long filename extends over the lower tile")
let namePoint = NSPoint(x: overlap.midX, y: overlap.midY)
state.enterHover(below, at: namePoint, trackPointer: false)
state.exitHover(owner, at: namePoint)
state.updateHover(at: namePoint, trackPointer: false)
require(state.hoverOwner === owner && state.hoveredFile?.path == owner.path, "crossing the expanded name never activates the lower tile")
let lowerPoint = NSPoint(x: tileRect(below).maxX - 4, y: tileRect(below).midY)
state.updateHover(at: lowerPoint, trackPointer: false)
require(state.hoverOwner === below, "leaving the expanded name allows deliberate hover on the next file")
let shortOwner = ordered[3]
state.hideHover()
state.enterHover(shortOwner, at: NSPoint(x: rects[3].midX, y: rects[3].midY), trackPointer: false)
let shortPreview = state.hoverPanel!.contentView as! FullNameHoverView
try verifyText(shortPreview, name: "short-name")
state.enterHover(ordered[6], at: NSPoint(x: rects[3].midX, y: rects[3].midY), trackPointer: false)
require(state.hoverOwner === shortOwner, "a short filename also retains ownership without lower-tile popup")
state.updateHover(at: NSPoint(x: screen.minX, y: screen.maxY), trackPointer: false)
require(state.hoverOwner == nil, "leaving all hover regions dismisses the preview")
state.hideHover()
pump()
require(state.hoveredFile == nil && !state.hoverPanel!.isVisible, "pointer exit restores the current tile")
state.showHover(owner)
state.showHover(below)
state.hideHover(owner)
require(state.hoveredFile?.path == below.path, "late exit cannot clear a newer hovered file")
state.hideHover()
window.setFrameOrigin(NSPoint(x: screen.maxX - 70, y: screen.minY - 180))
state.showHover(owner)
require(screen.contains(state.hoverPanel!.frame), "full name stays inside screen at its bottom-right edge")
state.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
require(state.hoveredFile == nil, "moving a partition clears its transient hover")
state.referenceDragInProgress = true
state.showHover(owner)
require(state.hoveredFile == nil, "dragging suppresses hover")
state.referenceDragInProgress = false
state.showHover(owner)
state.returnZonesToDesktop(reason: "test-app-switch")
require(state.hoveredFile == nil, "application switches restore hover visuals")
window.setFrameOrigin(NSPoint(x: screen.midX - 165, y: screen.midY - 210))
let stationaryFrame = window.frame
let savedFrame = state.store.zones[0].frameValue
for selected in [false, true] {
    state.selectedZone = selected ? id : nil
    state.selectedPaths = selected ? [files[0].path] : []
    state.showInFront()
    require(window.collectionBehavior.contains(.stationary) && window.frame == stationaryFrame, "front partition stays stationary with selection \(selected)")
    state.returnZonesToDesktop(reason: "test-blank-desktop")
    pump()
    require(window.collectionBehavior.contains(.stationary) && window.frame == stationaryFrame && state.store.zones[0].frameValue == savedFrame, "desktop focus change preserves partition geometry with selection \(selected)")
}
var reveals = 0
state.revealDesktopTestHook = { reveals += 1 }
final class ClickSink: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}
window.contentView = ClickSink(frame: host.frame)
for locked in [true, false] {
    state.store.zones[0].locked = locked
    for kind: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        let before = reveals
        let event = NSEvent.mouseEvent(with: kind, location: NSPoint(x: 15, y: 30), modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        window.sendEvent(event)
        require(reveals == before + 1, "locked or unlocked partition dispatches reveal for mouse button \(kind.rawValue)")
    }
}
require(DesktopRevealPolicy.shouldHide(bundle: "com.apple.finder", regular: true, ownPID: 1, pid: 2, hidden: false), "Finder is included in desktop reveal")
require(!DesktopRevealPolicy.shouldHide(bundle: "own", regular: true, ownPID: 1, pid: 1, hidden: false) && !DesktopRevealPolicy.shouldHide(bundle: "agent", regular: false, ownPID: 1, pid: 2, hidden: false), "own app and background processes are excluded")
var opened = false
state.openReferenceTestHook = { url, reveal in opened = url == files[1] && !reveal }
state.openReference(files[1].path, in: id)
require(opened && !state.pendingDesktopReveal && state.panels.values.allSatisfy { $0.level == state.desktopLevel }, "opening a document cancels pending reveal and returns partitions to desktop")
// Deterministic hide/restore checks use fake applications, never real processes.
final class FakeDesktopApplication: DesktopVisibilityApplication {
    let processIdentifier: pid_t
    var isHidden = false
    var isTerminated = false
    var acceptsHide = true
    var acceptsRestore = true
    var reportsHideFailure = false
    var reportsRestoreFailure = false
    var hides = 0
    var restores = 0
    let frame = NSRect(x: 31, y: 42, width: 700, height: 500)
    init(_ pid: pid_t, hidden: Bool = false) { processIdentifier = pid; isHidden = hidden }
    func hide() -> Bool { hides += 1; if acceptsHide { isHidden = true }; return acceptsHide && !reportsHideFailure }
    func unhide() -> Bool { restores += 1; if acceptsRestore { isHidden = false }; return acceptsRestore && !reportsRestoreFailure }
}
let browser = FakeDesktopApplication(7001)
let documentApp = FakeDesktopApplication(7002)
let previouslyHidden = FakeDesktopApplication(7003, hidden: true)
let rejected = FakeDesktopApplication(7004); rejected.acceptsHide = false
let session = DesktopVisibilitySession()
require(session.hide([browser, documentApp, previouslyHidden, rejected]) == 2, "first click hides only eligible visible apps")
require(session.isActive && session.applications?.count == 3 && previouslyHidden.hides == 0, "originally hidden apps are excluded from the restore snapshot")
_ = session.hide([browser, documentApp])
require(session.applications?.count == 3 && browser.hides == 1, "subsequent file clicks do not replace or duplicate the snapshot")
let windowsBefore = [browser.frame, documentApp.frame]
require(session.restore() == 2 && !session.isActive && !browser.isHidden && !documentApp.isHidden, "second blank click restores captured apps and resets the toggle")
require(previouslyHidden.isHidden && previouslyHidden.restores == 0 && rejected.restores == 0, "restore leaves prehidden and unsuccessfully hidden apps alone")
require([browser.frame, documentApp.frame] == windowsBefore, "hide and restore never alter document window geometry")
_ = session.hide([browser, documentApp]); documentApp.isTerminated = true
require(session.restore() == 1 && documentApp.restores == 1, "apps closed by the user are not relaunched during restore")
browser.acceptsRestore = false; _ = session.hide([browser]); _ = session.restore()
require(session.isActive && browser.isHidden, "a failed restore remains available for a later retry")
browser.acceptsRestore = true; _ = session.restore()
require(!session.isActive && !browser.isHidden, "retry completes without losing the hidden application")

let delayedApp = FakeDesktopApplication(7005)
delayedApp.reportsHideFailure = true
require(session.hide([delayedApp]) == 0 && delayedApp.isHidden && session.applications?.count == 1, "a delayed hide acknowledgment does not lose the restore snapshot")
delayedApp.reportsRestoreFailure = true
_ = session.restore(); session.confirmRestoration()
require(!delayedApp.isHidden && !session.isActive, "observed restoration clears a delayed unhide acknowledgment")

// Exercise the real native empty-space target. A click toggles, a drag selects.
window.contentView = DropContainer(app: state, zoneID: id, hosting: host)
pump(); window.contentView!.layoutSubtreeIfNeeded()
let selection = window.contentView!.subviews.compactMap { $0 as? SelectionSurface }.first!
let blank = selection.convert(NSPoint(x: selection.area.minX + 20, y: selection.area.minY + 6), to: nil)
require(window.contentView!.hitTest(blank) is SelectionSurface, "partition blank space has a native toggle target")
func send(_ type: NSEvent.EventType, _ point: NSPoint) {
    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 30, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
    window.sendEvent(event)
}
_ = state.desktopVisibility.hide([browser])
let hideCount = reveals
send(.leftMouseDown, blank)
require(browser.isHidden && reveals == hideCount, "blank press retains the snapshot until mouse release")
send(.leftMouseUp, blank)
require(!browser.isHidden && !state.desktopVisibility.isActive, "native blank click restores the previous windows")
_ = state.desktopVisibility.hide([browser])
send(.leftMouseDown, blank)
let dragged = NSPoint(x: blank.x + 20, y: blank.y + 20)
send(.leftMouseDragged, dragged); send(.leftMouseUp, dragged)
require(browser.isHidden && state.desktopVisibility.isActive, "selection drag does not toggle other windows")
_ = state.desktopVisibility.restore()
_ = state.desktopVisibility.hide([browser])
let fileTile = state.tileViews.allObjects.first { $0.path == files[0].path && $0.window === window }!
let filePoint = fileTile.convert(NSPoint(x: fileTile.bounds.midX, y: fileTile.bounds.midY), to: nil)
send(.leftMouseDown, filePoint); send(.leftMouseUp, filePoint)
require(browser.isHidden && state.desktopVisibility.isActive, "clicking a file does not restore background windows")
state.openReference(files[1].path, in: id)
require(state.desktopVisibility.isActive && opened, "opening a document preserves the snapshot for the next blank click")
state.restoreDesktopApplications()
require(!browser.isHidden && window.frame == stationaryFrame, "restoring windows keeps the partition at its original position")

let bytesAfter = try files.map { try Data(contentsOf: $0) }
require(bytesAfter == bytesBefore, "fixture file bytes are unchanged")
let saved = try ReferenceStore(root: fixtures, config: state.store.config, allowPersonalFiles: true)
require(saved.zones.map(\.paths) == referencePathsBefore, "hover and click do not change stored references")
window.orderOut(nil)
state.hideHover()

// Real production window, scrollbar gutter, resize handle and persistence.
let narrowZone = Zone(title: "单列分区验收", paths: files.map(\.path), x: screen.midX, y: screen.midY - 210, width: 300, height: 420, locked: false, organizeFiles: false)
state.store.zones.append(narrowZone)
state.makePanel(narrowZone)
let narrowPanel = state.panels[narrowZone.id]!
narrowPanel.level = .normal
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func settleNarrow() { pump(); narrowPanel.contentView!.layoutSubtreeIfNeeded(); narrowPanel.contentView!.displayIfNeeded() }
settleNarrow()
let handle = descendants(narrowPanel.contentView!).compactMap { $0 as? ResizeView }.first!
func resizeEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 40, windowNumber: narrowPanel.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0)!
}
let initialTop = narrowPanel.frame.maxY
handle.mouseDown(with: resizeEvent(.leftMouseDown, at: NSPoint(x: 290, y: 10)))
handle.mouseDragged(with: resizeEvent(.leftMouseDragged, at: NSPoint(x: -1000, y: 10)))
handle.mouseUp(with: resizeEvent(.leftMouseUp, at: NSPoint(x: 0, y: 10)))
settleNarrow()
let minimumWidth = PartitionWindowLayout.minimumWidth
require(abs(narrowPanel.frame.width - minimumWidth) < 0.01 && narrowPanel.frame.maxY == initialTop, "resize handle stops at one-column minimum without moving the top edge")
require(narrowPanel.minSize.width == minimumWidth && GridDropLayout.columnCount(width: minimumWidth) == 1, "native border resize shares the one-column width limit")
let scrollView = descendants(narrowPanel.contentView!).compactMap { $0 as? NSScrollView }.first!
scrollView.scrollerStyle = .legacy; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = false
settleNarrow()
let firstNarrow = state.tileViews.allObjects.first { $0.window === narrowPanel && $0.path == files[0].path }!
let nextNarrow = state.tileViews.allObjects.first { $0.window === narrowPanel && $0.path == files[1].path }!
let firstClipRect = firstNarrow.convert(firstNarrow.bounds, to: scrollView.contentView)
require(firstClipRect.minX >= scrollView.contentView.bounds.minX && firstClipRect.maxX <= scrollView.contentView.bounds.maxX + 0.01, "one complete file cell fits beside an always-visible scrollbar")
require(abs(tileRect(firstNarrow).minX - tileRect(nextNarrow).minX) < 0.01 && abs(tileRect(firstNarrow).minY - tileRect(nextNarrow).minY - 84) < 0.01, "minimum-width files form one column with unchanged spacing")
require(firstNarrow.bounds.width == 81 && firstNarrow.bounds.height == 81, "narrow layout preserves existing file cell dimensions")
for view in descendants(narrowPanel.contentView!) where String(describing: type(of: view)).contains("Menu") {
    print("NARROW HEADER: \(type(of: view)) frame=\(view.convert(view.bounds, to: narrowPanel.contentView!))")
}
let narrowBitmap = narrowPanel.contentView!.bitmapImageRepForCachingDisplay(in: narrowPanel.contentView!.bounds)!
narrowPanel.contentView!.cacheDisplay(in: narrowPanel.contentView!.bounds, to: narrowBitmap)
try narrowBitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("one-column.png"))
state.showHover(firstNarrow)
require((state.hoverPanel?.contentView as? FullNameHoverView)?.name == names[0] && screen.contains(state.hoverPanel!.frame), "one-column hover still shows the complete name within the display")
state.hideHover()
state.lock(narrowZone.id); settleNarrow()
require(narrowPanel.frame.width == minimumWidth && !narrowPanel.styleMask.contains(.resizable), "locking a one-column partition preserves its narrow width")
state.toggleCollapsed(narrowZone.id); settleNarrow()
require(narrowPanel.frame.width == minimumWidth && state.zone(narrowZone.id).isCollapsed, "collapsing a one-column partition preserves its width")
state.toggleCollapsed(narrowZone.id); state.lock(narrowZone.id); settleNarrow()
require(narrowPanel.frame.width == minimumWidth && narrowPanel.styleMask.contains(.resizable), "expanding and unlocking retain the new minimum")
state.toggleMaximum(narrowZone.id, itemCount: 9); settleNarrow()
require(narrowPanel.frame.width > minimumWidth, "one-column partition can expand to show multiple columns")
state.toggleMaximum(narrowZone.id); settleNarrow()
require(narrowPanel.frame.width == minimumWidth, "restore returns exactly to the saved one-column width")
let reloaded = try ReferenceStore(root: fixtures, config: state.store.config, allowPersonalFiles: true)
require(reloaded.zones.first { $0.id == narrowZone.id }!.width == minimumWidth, "one-column width is saved for the next launch")
narrowPanel.orderOut(nil)
state.makePanel(state.zone(narrowZone.id))
pump()
require(state.panels[narrowZone.id]!.frame.width == minimumWidth, "recreating the native window does not widen a saved one-column partition")
state.panels[narrowZone.id]!.orderOut(nil)

// Menu width is independent from the one-column window, including submenus.
let menuPanel = state.panels[narrowZone.id]!
let menuControl = descendants(menuPanel.contentView!).compactMap { $0 as? PartitionMenuControl }.first!
let completeMenu = menuControl.makeMenu!()
func nestedMenus(_ menu: NSMenu) -> [NSMenu] { [menu] + menu.items.compactMap(\.submenu).flatMap(nestedMenus) }
let menus = nestedMenus(completeMenu)
require(menus.count == 3, "main menu and both option submenus remain available")
require(completeMenu.size.width > menuPanel.frame.width, "popup grows wider than a one-column partition")
require(menus.allSatisfy { menu in menu.items.filter { !$0.isSeparatorItem }.allSatisfy { item in
    (item.title as NSString).size(withAttributes: [.font: menu.font ?? NSFont.menuFont(ofSize: 0)]).width + 48 <= menu.size.width
} }, "every complete command fits in its actual native menu width")
require(menus.flatMap(\.items).allSatisfy { !$0.title.contains("…") && !$0.title.contains("...") }, "partition menu commands contain no replacement ellipses")
let nativeMenuFrame = menuControl.convert(menuControl.bounds, to: menuPanel.contentView!)
require(menuControl.bounds.size == NSSize(width: 34, height: 34) && menuPanel.contentView!.bounds.contains(nativeMenuFrame), "More trigger retains its full clickable area within the narrow header")
let importMenu = completeMenu.items.first { $0.title == L("拖入方式", "Import Mode") }!.submenu!
require(importMenu.items[1].state == .on && importMenu.items[0].state == .off, "import-mode selection is retained")
let sortMenu = completeMenu.items.first { $0.title == L("排序", "Sort By") }!.submenu!
(sortMenu.items[1] as! PartitionMenuAction).invoke()
require(state.zone(narrowZone.id).sortOrder == "name", "native sort command updates only the intended partition")
let refreshedMenu = menuControl.makeMenu!()
let sortRefreshed = refreshedMenu.items.first { $0.title == L("排序", "Sort By") }!.submenu!
require(sortRefreshed.items[1].state == .on && sortRefreshed.items[0].state == .off, "reopened menu refreshes selection checkmarks")
let lockCommand = refreshedMenu.items.first { $0.title == L("锁定分区（固定位置与文件）", "Lock Partition (Fix Position and Files)") } as! PartitionMenuAction
lockCommand.invoke(); pump()
let lockedMenu = descendants(menuPanel.contentView!).compactMap { $0 as? PartitionMenuControl }.first!.makeMenu!()
require(state.zone(narrowZone.id).locked && lockedMenu.items.first { $0.title == L("添加文档、图片或文件夹", "Add Documents, Images, or Folders") }?.isEnabled == false, "locked menu preserves the disabled add-files action")
let fullUnlock = L("解锁分区（允许移动文件和分区）", "Unlock Partition (Allow Moving Files and Partition)")
require(lockedMenu.item(withTitle: fullUnlock) != nil && lockedMenu.size.width >= (fullUnlock as NSString).size(withAttributes: [.font: lockedMenu.font ?? NSFont.menuFont(ofSize: 0)]).width + 48, "long unlock explanation is retained and fits in full")
(lockedMenu.item(withTitle: fullUnlock) as! PartitionMenuAction).invoke(); pump()
require(!state.zone(narrowZone.id).locked && menuPanel.frame.width == minimumWidth, "unlock action preserves the one-column geometry")
let englishMenu = NSMenu()
englishMenu.addItem(PartitionMenuAction("Unlock Partition (Allow Moving Files and Partition)") {})
PartitionMenuLayout.fit(englishMenu)
require(englishMenu.size.width > minimumWidth && englishMenu.size.width >= (englishMenu.items[0].title as NSString).size(withAttributes: [.font: englishMenu.font ?? NSFont.menuFont(ofSize: 0)]).width + 48, "long English commands also receive sufficient native menu width")
print("ALL HOVER AND DESKTOP CALLBACK CHECKS PASSED")

// Automated test app exits after flushing its report; no test window is left open.
fflush(stdout)
if Bundle.main.object(forInfoDictionaryKey: "PansDesktopInspectMenu") as? Bool == true {
    nativeApp.setActivationPolicy(.regular)
    let bar = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
    let quit = NSMenuItem(title: "Quit Checks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = nativeApp; appMenu.addItem(quit); appItem.submenu = appMenu; bar.addItem(appItem); nativeApp.mainMenu = bar
    menuPanel.level = .normal; menuPanel.orderFrontRegardless()
    let inspectionControl = descendants(menuPanel.contentView!).compactMap { $0 as? PartitionMenuControl }.first!
    let normalFactory = inspectionControl.makeMenu!
    var inspectionMenu: NSMenu?
    inspectionControl.makeMenu = { let menu = normalFactory(); inspectionMenu = menu; return menu }
    var inspectionSamples = 0
    let inspectionTimer = Timer(timeInterval: 0.25, repeats: true) { timer in
        guard inspectionMenu != nil else { return }
        inspectionSamples += 1
        if inspectionSamples == 2 {
            for popup in nativeApp.windows where popup.isVisible {
                print("ACTUAL INSPECTION WINDOW: \(type(of: popup)) frame=\(popup.frame)")
            }
            fflush(stdout)
        }
        if inspectionSamples == 8 { inspectionMenu?.cancelTracking(); timer.invalidate() }
    }
    RunLoop.current.add(inspectionTimer, forMode: .common)
    RunLoop.current.add(inspectionTimer, forMode: .eventTracking)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { inspectionControl.openMenu() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { exit(0) }
    nativeApp.run()
}
exit(0)
