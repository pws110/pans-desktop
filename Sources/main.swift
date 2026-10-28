import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookUI
import ImageIO

let referenceType = "com.andy.clearzones.reference"

enum PartitionWindowLayout {
    // Keep one complete grid cell plus its existing margins, even when macOS
    // reserves a legacy scrollbar gutter instead of using an overlay scroller.
    static var minimumWidth: CGFloat {
        GridDropLayout.rowHeight + 2 * GridDropLayout.padding
            + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }
}

// A clicked partition must accept normal app focus while showing the desktop.
// Returning to desktop level on app switches keeps other documents usable.
final class ZonePanel: NSWindow {
    weak var controller: AppState?
    private var restoreClickOrigin: NSPoint?
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { controller?.backToDesktop() } else { super.keyDown(with: event) } }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { controller?.hideHover() }
        if event.type == .leftMouseDown {
            controller?.desktopVisibility.confirmRestoration()
            restoreClickOrigin = nil
            if controller?.desktopVisibility.isActive == true, let contentView,
               contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) is SelectionSurface {
                restoreClickOrigin = event.locationInWindow
            } else { controller?.revealDesktopForInteraction(in: self) }
        } else if [.rightMouseDown, .otherMouseDown].contains(event.type) {
            restoreClickOrigin = nil
            controller?.revealDesktopForInteraction(in: self)
        } else if event.type == .leftMouseDragged, let origin = restoreClickOrigin,
                  hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 {
            restoreClickOrigin = nil
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp, restoreClickOrigin != nil {
            restoreClickOrigin = nil
            controller?.restoreDesktopApplications()
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class PreviewWindow: NSWindow {
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) } }
}
final class TrialWindow: NSWindow {
    weak var controller: AppState?
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { controller?.backToDesktop() } else { super.keyDown(with: event) } }
}
final class AppState: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    @Published var revision = 0
    var store: ReferenceStore!
    var storage: StorageEngine!
    var partitionArchive: PartitionArchive!
    var historyWindow: NSWindow?
    var previewWindow: NSWindow?
    var clickTracker = TileClickTracker()
    var sharingPickers: [NSSharingServicePicker] = []
    var pendingDesktopReveal = false
    var desktopFocusMode = false
    var desktopRevealGeneration = 0
    let desktopVisibility = DesktopVisibilitySession()
    var desktopReturnApplication: NSRunningApplication?
    var lastExternalApplication: NSRunningApplication?
    weak var desktopFocusPanel: ZonePanel?
    var revealDesktopTestHook: (() -> Void)?
    var openReferenceTestHook: ((URL, Bool) -> Void)?
    var selectedPath: String?
    var selectedPaths: Set<String> = []
    let tileViews = NSHashTable<ReferenceTileView>.weakObjects()
    let gridCells = NSHashTable<GridCellView>.weakObjects()
    var handledDragSessions: Set<UUID> = []
    var selectedZone: UUID?
    var fileOperationRunning = false
    @Published var hoveredFile: (zone: UUID, path: String)?
    var hoverPanel: NSPanel?
    weak var hoverOwner: ReferenceTileView?
    var hoverPointerTimer: Timer?
    var panels: [UUID: ZonePanel] = [:]
    var frontExpandedZone: UUID?
    var status: NSStatusItem!
    var trialWindow: NSWindow?
    var loading = false
    var started = false
    var showing = true
    var referenceDragInProgress = false
    var referenceRefreshRunning = false
    var referenceTimer: Timer?
    var workspaceActivationObserver: NSObjectProtocol?
    let referenceQueue = DispatchQueue(label: "com.andy.clearzones.reference-refresh", qos: .utility)
    let traceQueue = DispatchQueue(label: "com.andy.clearzones.diagnostics", qos: .utility)
    let imageQueue = DispatchQueue(label: "com.andy.clearzones.thumbnails", qos: .utility, attributes: .concurrent)
    var imageCache: [String: NSImage] = [:]
    var sizeCache: [String: String] = [:]
    var imageRequests: Set<String> = []
    func fileImage(_ path: String) -> NSImage {
        if let image = imageCache[path] { return image }
        let url = URL(fileURLWithPath: path)
        let imageType = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"].contains(url.pathExtension.lowercased())
        if imageRequests.insert(path).inserted {
            imageQueue.async { [weak self] in
                var size = L("大小暂不可用", "Size unavailable")
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                    if values.isDirectory == true { size = L("文件夹", "Folder") }
                    else if let count = values.fileSize { size = AppLanguage.byteCount(count) }
                }
                var result: NSImage?
                if imageType, let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    result = NSImage(cgImage: cg, size: .zero)
                }
                let image = result ?? NSWorkspace.shared.icon(forFile: path)
                DispatchQueue.main.async {
                    self?.imageCache[path] = image; self?.sizeCache[path] = size; self?.revision += 1
                }
            }
        }
        return NSImage(systemSymbolName: imageType ? "photo" : "doc", accessibilityDescription: nil) ?? NSImage()
    }
    @Published var preview = false
    var hoveredZone: UUID?
    let dropViews = NSHashTable<DropContainer>.weakObjects()
    private let dataHome = Result { try AppDataHome.resolve(bundleURL: Bundle.main.bundleURL, bookmarkURL: Bundle.main.url(forResource: "ExistingDataHome", withExtension: "bookmark")) }
    var home: URL {
        switch dataHome {
        case .success(let url): return url
        case .failure: preconditionFailure("The data location must be validated before use")
        }
    }
    var sampleRoot: URL { home.appendingPathComponent("TestFiles", isDirectory: true) }
    func keepApplicationAvailable() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { startUI() }
    func startUI() {
        guard !started else { return }
        started = true
        keepApplicationAvailable()
        DispatchQueue.main.async { [weak self] in self?.keepApplicationAvailable() }
        trace("startup did-finish")
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApplication = front }
        do {
            _ = try dataHome.get()
            let config = home.appendingPathComponent("Configuration/zones.json")
            let firstLaunch = !FileManager.default.fileExists(atPath: config.path)
            store = try ReferenceStore(root: sampleRoot, config: config, allowPersonalFiles: true)
            if firstLaunch { try seed() }
            partitionArchive = try PartitionArchive(url: home.appendingPathComponent("Configuration/deleted-partitions.json"))
            storage = try StorageEngine(home: home, references: store)
            trace("startup config-loaded")
            installMenu()
            trace("startup menu-ready")
            for zone in store.zones { trace("startup before-panel " + zone.title); makePanel(zone); trace("startup after-panel " + zone.title) }
            backToDesktop()
            workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.trace("external-application-activated bundle=\(application.bundleIdentifier ?? "unknown") pid=\(application.processIdentifier)")
                self?.lastExternalApplication = application
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.pendingDesktopReveal,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return }
                    self.returnZonesToDesktop(reason: "external-app-activated")
                }
            }
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refreshReferences() }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            referenceTimer = timer
            refreshReferences()
            if FileManager.default.fileExists(atPath: home.appendingPathComponent("Configuration/desktop-copy-acceptance").path) {
                showTrial()
            }
        } catch { alert(L("无法启动", "Unable to Start"), error.localizedDescription); NSApp.terminate(nil) }
    }
    func seed() throws {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        for (i, title) in [L("常用文件", "Favorites"), L("临时文件", "Temporary"), L("图片素材", "Images"), L("待处理", "Inbox")].enumerated() {
            let width = min(280.0, (screen.width - 100) / 4)
            store.zones.append(Zone(title: title, x: screen.maxX - 20 - width - Double(i) * (width + 14), y: screen.maxY - 306, width: width))
        }
        try store.save()
    }
    func installMenu() {
        NSApp.registerServicesMenuSendTypes([.fileURL, .string, NSPasteboard.PasteboardType("NSFilenamesPboardType")], returnTypes: [])
        let main = NSMenu(), item = NSMenuItem(), menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action, key) in [(L("把分区带到前面", "Bring Partitions Forward"), #selector(showInFront), ""), (L("放回桌面层", "Return to Desktop Layer"), #selector(backToDesktop), ""), (L("新增分区（向右排列）", "Add Partition to the Right"), #selector(addZone), ""), (L("恢复上次删除的分区", "Restore Last Deleted Partition"), #selector(restorePartition), ""), (L("添加到待处理…", "Add to Inbox…"), #selector(addToInbox), ""), (L("撤销上次操作", "Undo Last Action"), #selector(undoStorage), ""), (L("操作记录", "Activity History"), #selector(showHistory), ""), (L("打开收纳文件夹", "Open Storage Folder"), #selector(openStorage), ""), (L("刷新文件引用", "Refresh File References"), #selector(refreshReferences), ""), (L("退出Pan's Desktop", "Quit Pan's Desktop"), #selector(quit), "q")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self
            if action == #selector(restorePartition) { entry.isEnabled = partitionArchive.restorable(in: store) != nil }
            if action == #selector(addToInbox) { entry.isEnabled = store.zones.contains { AppLanguage.isInboxTitle($0.title) } }
            menu.addItem(entry)
        }
        let zonesItem = NSMenuItem(title: L("显示指定分区", "Show Partition"), action: nil, keyEquivalent: ""), zonesMenu = NSMenu()
        for zone in store.zones {
            let entry = NSMenuItem(title: zone.title, action: #selector(focusZone(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = zone.id.uuidString; zonesMenu.addItem(entry)
        }
        zonesItem.submenu = zonesMenu; menu.insertItem(zonesItem, at: 2)
        let trial = NSMenuItem(title: L("示例文件篮", "Sample File Basket"), action: #selector(showTrial), keyEquivalent: ""); trial.target = self; menu.insertItem(trial, at: menu.numberOfItems - 1)
        item.submenu = menu; main.addItem(item); NSApp.mainMenu = main
        if status == nil { status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        status.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Pan's Desktop")
        status.button?.toolTip = L("Pan's Desktop · 收纳与引用", "Pan's Desktop · Collect and Reference")
        let statusMenu = menu.copy() as! NSMenu
        status.menu = statusMenu
    }
    func makePanel(_ zone: Zone) {
        loading = true
        let panel = ZonePanel(contentRect: NSRect(x: zone.x, y: zone.y, width: zone.width, height: zone.height), styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        panel.controller = self
        panel.title = "Pan's Desktop · \(zone.title)"; panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.08)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.tabbingMode = .disallowed
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
        panel.setFrame(NSRect(x: zone.x, y: zone.y, width: zone.width, height: zone.height), display: false)
        panel.ignoresMouseEvents = false; panel.acceptsMouseMovedEvents = true
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = !zone.locked
        panel.isMovableByWindowBackground = false; panel.minSize = NSSize(width: PartitionWindowLayout.minimumWidth, height: zone.isCollapsed ? 48 : 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = desktopLevel
        let hosting = NSHostingView(rootView: ZoneView(app: self, id: zone.id))
        hosting.safeAreaRegions = []
        panel.contentView = DropContainer(app: self, zoneID: zone.id, hosting: hosting)
        if zone.locked || zone.isCollapsed || zone.isMaximized { panel.styleMask.remove(.resizable) }
        panel.delegate = self; panels[zone.id] = panel; panel.orderFrontRegardless()
        loading = false
        raiseExpandedPartitions()
    }
    // Keep expanded zones above sibling zones at their existing window level.
    // Never activate the app, change desktop levels or unhide a hidden panel.
    func raiseExpandedPartitions(preferred id: UUID? = nil) {
        guard showing, let store else { return }
        let expanded = store.zones.filter { $0.isMaximized && !$0.isCollapsed && panels[$0.id]?.isVisible == true }.map(\.id)
        if let id, expanded.contains(id) { frontExpandedZone = id }
        if let frontExpandedZone, !expanded.contains(frontExpandedZone) { self.frontExpandedZone = nil }
        let order = expanded.filter { $0 != frontExpandedZone } + (frontExpandedZone.map { [$0] } ?? [])
        for zoneID in order { panels[zoneID]?.orderFrontRegardless() }
    }
    var desktopLevel: NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1) }
    func zone(_ id: UUID) -> Zone { store.zones.first { $0.id == id }! }
    func change(_ id: UUID, _ body: (inout Zone) -> Void) {
        guard let i = store.zones.firstIndex(where: { $0.id == id }) else { return }
        let previous = store.zones
        body(&store.zones[i])
        do { try store.save() } catch { store.zones = previous; alert(L("保存失败", "Unable to Save"), error.localizedDescription) }
        revision += 1
    }
    func persist() { do { try store.save() } catch { alert(L("保存失败", "Unable to Save"), error.localizedDescription) } }
    func windowDidMove(_ notification: Notification) { hideHover(); remember(notification) }
    func windowDidResize(_ notification: Notification) { hideHover(); remember(notification) }
    func remember(_ notification: Notification) {
        guard !loading, let panel = notification.object as? ZonePanel, let pair = panels.first(where: { $0.value === panel }) else { return }
        let saved = zone(pair.key)
        // Native title-bar dragging and window-management paths must obey the
        // same lock as our custom title view. Never persist a locked move.
        if saved.locked {
            let expected = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if panel.frame != expected {
                loading = true; panel.setFrame(expected, display: true); loading = false
                trace("locked-geometry-restored title=" + saved.title)
            }
            return
        }
        guard !saved.isMaximized else { return }
        let f = panel.frame
        change(pair.key) { $0.x = f.minX; $0.y = f.minY; $0.width = f.width; $0.height = f.height }
    }
    func traceDesktopInput(_ action: String) {
        let front = NSWorkspace.shared.frontmostApplication
        trace("desktop-input action=\(action) appActive=\(NSApp.isActive) front=\(front?.bundleIdentifier ?? "unknown")")
    }
    func rename(_ id: UUID) {
        let input = NSTextField(string: zone(id).title); input.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        let a = NSAlert(); a.messageText = L("分区名称", "Partition Name"); a.informativeText = L("只修改分区标签，不改文件夹或原文件名。", "This changes only the partition label, not the folder or original file name."); a.accessoryView = input
        a.addButton(withTitle: L("保存", "Save")); a.addButton(withTitle: L("取消", "Cancel")); NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = input
        if a.runModal() == .alertFirstButtonReturn {
            a.window.makeFirstResponder(nil)
            let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { change(id) { $0.title = String(title.prefix(40)) }; panels[id]?.title = "Pan's Desktop · \(zone(id).title)"; installMenu() }
        }
    }
    func lock(_ id: UUID) {
        change(id) { $0.locked.toggle() }
        applyPanelGeometry(id)
    }
    func hideHover(_ owner: ReferenceTileView? = nil) {
        if let owner, hoverOwner !== owner { return }
        hoverPointerTimer?.invalidate(); hoverPointerTimer = nil
        hoverPanel?.orderOut(nil)
        hoverOwner = nil
        if hoveredFile != nil { hoveredFile = nil }
    }
    func hoverContains(_ point: NSPoint) -> Bool {
        guard let owner = hoverOwner, let window = owner.window, window.isVisible,
              !owner.visibleRect.intersection(owner.bounds).isEmpty else { return false }
        let anchor = window.convertToScreen(owner.convert(owner.visibleRect.intersection(owner.bounds), to: nil))
        return anchor.contains(point) || (hoverPanel?.isVisible == true && hoverPanel!.frame.insetBy(dx: -2, dy: -2).contains(point))
    }
    func enterHover(_ owner: ReferenceTileView, at point: NSPoint, trackPointer: Bool = true) {
        // Expanded names keep their owner even when a lower tile receives a
        // native mouse-enter event through the transparent preview window.
        if hoverContains(point) { return }
        hideHover()
        showHover(owner)
        if trackPointer, hoverOwner != nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateHover(at: NSEvent.mouseLocation)
            }
            hoverPointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func exitHover(_ owner: ReferenceTileView, at point: NSPoint) {
        guard hoverOwner === owner, !hoverContains(point) else { return }
        updateHover(at: point)
    }
    func updateHover(at point: NSPoint, trackPointer: Bool = true) {
        guard hoverOwner != nil else { return }
        if referenceDragInProgress || NSEvent.pressedMouseButtons != 0 { hideHover(); return }
        if hoverContains(point) { return }
        let previousWindow = hoverOwner?.window
        hideHover()
        // The timer also catches leaving the name into a tile whose initial
        // mouse-enter was intentionally ignored. Never change any grid frame.
        if let next = tileViews.allObjects.first(where: { tile in
            guard !tile.fileURLSource, tile.window === previousWindow,
                  let window = tile.window, window.isVisible, !tile.isHiddenOrHasHiddenAncestor else { return false }
            let visible = tile.visibleRect.intersection(tile.bounds)
            return !visible.isEmpty && window.convertToScreen(tile.convert(visible, to: nil)).contains(point)
        }) { enterHover(next, at: point, trackPointer: trackPointer) }
    }
    func showHover(_ owner: ReferenceTileView) {
        guard !referenceDragInProgress, NSEvent.pressedMouseButtons == 0,
              let source = owner.window, owner.superview != nil else { return }
        let anchor = source.convertToScreen(owner.convert(owner.bounds, to: nil))
        let screen = (source.screen ?? NSScreen.main)?.visibleFrame ?? source.frame
        let content = FullNameHoverView(name: URL(fileURLWithPath: owner.path).lastPathComponent,
                                        icon: owner.icon ?? NSWorkspace.shared.icon(forFile: owner.path),
                                        availableSize: screen.insetBy(dx: 8, dy: 8).size)
        let size = content.frame.size
        // Preserve the icon's baseline; only shift the preview at screen edges
        // so every line of the full name remains visible.
        let desiredTop = anchor.maxY - 3 + (content.iconSize.height - 42) + FullNameHoverView.inset
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let y = min(max(desiredTop - size.height, screen.minY + 8), screen.maxY - size.height - 8)
        let panel = hoverPanel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: source.level.rawValue + 1)
        panel.contentView = content
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        hoverPanel = panel; hoverOwner = owner
        // Only replace the current tile's visuals. Every neighbor stays drawn
        // in its original place underneath this transparent full-name preview.
        if hoveredFile?.zone != owner.zone || hoveredFile?.path != owner.path {
            hoveredFile = (zone: owner.zone, path: owner.path)
        }
        panel.orderFrontRegardless()
    }
    func applyPanelGeometry(_ id: UUID) {
        hideHover()
        guard let panel = panels[id] else { return }
        let z = zone(id); loading = true
        panel.isMovable = !z.locked
        panel.minSize = NSSize(width: PartitionWindowLayout.minimumWidth, height: z.isCollapsed ? 48 : 180)
        if z.locked || z.isCollapsed || z.isMaximized { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
        panel.setFrame(NSRect(x: z.x, y: z.y, width: z.width, height: z.height), display: true)
        panel.orderFrontRegardless(); loading = false
        raiseExpandedPartitions(preferred: id)
    }
    func toggleMaximum(_ id: UUID, itemCount: Int? = nil, extraHeight: Double = 0) {
        let frame = (panels[id]?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        change(id) { $0.toggleMaximum(on: ZoneFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), itemCount: itemCount, extraHeight: extraHeight) }
        applyPanelGeometry(id)
    }
    func toggleCollapsed(_ id: UUID) { change(id) { $0.toggleCollapsed() }; applyPanelGeometry(id) }
    func performFileOperation(_ operation: () throws -> Void) {
        guard !fileOperationRunning else { return }
        fileOperationRunning = true
        defer { fileOperationRunning = false; if let id = selectedZone { selectedPaths.formIntersection(Set(zone(id).paths)); if let path = selectedPath, !selectedPaths.contains(path) { selectedPath = selectedPaths.first } }; revision += 1; refreshReferences() }
        do { try operation() } catch { alert(L("操作未完成", "Action Incomplete"), error.localizedDescription) }
    }
    func importFiles(_ urls: [URL], to id: UUID, from source: UUID? = nil) {
        if zone(id).usesStorage { performFileOperation { _ = try storage.collect(urls, to: id, sourceZone: source) } }
        else { add(urls, to: id, from: source) }
    }
    func chooseFiles(_ id: UUID) {
        guard !zone(id).locked else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = zone(id).usesStorage ? L("文件将移到桌面之外的收纳文件夹，可撤销或放回原位置。", "Files will be moved to the storage folder off the desktop. You can undo the action or return them to their original locations.") : L("只添加引用，原文件位置不变。", "Add references only. Original files stay in place.")
        panel.prompt = zone(id).usesStorage ? L("收纳文件", "Collect Files") : L("添加引用", "Add References")
        panel.allowedContentTypes = [.image, .folder] + ["pdf","txt","md","rtf","doc","docx","xls","xlsx","ppt","pptx","pages","numbers","key","csv","epub","odt"].compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in if result == .OK { self?.importFiles(panel.urls, to: id) } }
    }
    @objc func addToInbox() { if let id = store.zones.first(where: { AppLanguage.isInboxTitle($0.title) })?.id { chooseFiles(id) } }
    @objc func undoStorage() { performFileOperation { _ = try storage.undo() } }
    @objc func openStorage() { returnZonesToDesktop(reason: "open-storage"); NSWorkspace.shared.open(storage.root) }
    func openZoneFolder(_ id: UUID) { do { let folder = try storage.folder(id); returnZonesToDesktop(reason: "open-zone-folder"); NSWorkspace.shared.open(folder) } catch { alert(L("无法打开", "Unable to Open"), error.localizedDescription) } }
    func returnOriginal(_ path: String, in id: UUID) {
        guard let url = store.resolvedURL(path, in: id) else { alert(L("原文件暂不可用", "Original File Unavailable"), StoreFailure.unavailableReference.localizedDescription); return }
        performFileOperation { _ = try storage.returnToOriginal(url, sourceZone: id) }
    }
    func setSelection(_ paths: Set<String>, in id: UUID, anchor: String? = nil) {
        selectedZone = id; selectedPaths = paths.intersection(Set(zone(id).paths))
        selectedPath = anchor ?? selectedPaths.first; revision += 1
    }
    func selectFile(_ path: String, in id: UUID, modifiers: NSEvent.ModifierFlags, order: [String]) {
        var current = selectedZone == id ? selectedPaths : []
        if modifiers.contains(.shift), selectedZone == id, let anchor = selectedPath,
           let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: path) {
            let range = Set(order[min(a,b)...max(a,b)])
            setSelection(modifiers.contains(.command) ? current.union(range) : range, in: id, anchor: anchor)
        } else if modifiers.contains(.command) {
            if current.contains(path) { current.remove(path) } else { current.insert(path) }
            setSelection(current, in: id, anchor: path)
        } else { setSelection([path], in: id, anchor: path) }
    }
    func actionPaths(_ path: String, in id: UUID) -> [String] {
        if selectedZone == id, selectedPaths.contains(path) { return zone(id).paths.filter { selectedPaths.contains($0) } }
        return [path]
    }
    func resolvedBatch(_ paths: [String], in id: UUID) throws -> [URL] {
        try paths.map { path in guard let url = store.resolvedURL(path, in: id) else { throw StoreFailure.unavailableReference }; return url }
    }
    func moveToDesktop(_ path: String, in id: UUID) {
        guard !zone(id).locked, store.resolvedURL(path, in: id) != nil else { alert(L("无法移动", "Unable to Move"), L("请先解锁分区并确认原文件可用。", "Unlock the partition and check that the original file is available.")); return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        performFileOperation { _ = try storage.moveOut(try resolvedBatch(actionPaths(path, in: id), in: id), toDirectory: desktop, sourceZone: id); selectedPath = nil; selectedPaths = []; selectedZone = nil }
    }
    func trashFile(_ path: String, in id: UUID) {
        guard !zone(id).locked, let url = store.resolvedURL(path, in: id) else { alert(L("无法移到废纸篓", "Unable to Move to Trash"), L("请先解锁分区并确认原文件可用。", "Unlock the partition and check that the original file is available.")); return }
        performFileOperation { _ = try storage.trash(url, sourceZone: id); selectedPath = nil; selectedPaths = []; selectedZone = nil }
    }
    func finishNativeMove(_ item: FileMoveItem, sourceZone: UUID? = nil, attempts: Int = 240) {
        // Some Finder/Dock versions report a completed Trash drop as .move.
        // Reconcile only a bookmark whose exact file identity is now in Trash.
        if let sourceZone, !StorageEngine.exists(item.source.path), StorageEngine.verifiedTrashURL(item.tracking) != nil {
            performFileOperation { _ = try storage.finishExternalTrash(item.source, tracking: item.tracking, sourceZone: sourceZone) }
            return
        }
        // A drop into another zone has already been committed by StorageEngine.
        if let found = ReferenceStore.resolve(item.source.path, tracking: item.tracking, root: sampleRoot, allowPersonalFiles: true), found.url.path != item.source.path, storage.isManaged(found.url) { return }
        do {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
            if try storage.finishExternalMove(item.source, tracking: item.tracking, sameLocationAccepted: item.source.deletingLastPathComponent().path == desktop, sourceZone: sourceZone) {
                revision += 1; trace("export-move-success"); refreshReferences(); return
            }
        } catch { alert(L("文件已移动，请核对分区记录", "File Moved — Check Partition Records"), error.localizedDescription); return }
        if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finishNativeMove(item, sourceZone: sourceZone, attempts: attempts - 1) } }
        else { trace("export-move-not-observed; references retained") }
    }
    func previewReference(_ path: String, in id: UUID) {
        hideHover()
        guard let url = store.resolvedURL(path, in: id) else { alert(L("原文件暂不可用", "Original File Unavailable"), StoreFailure.unavailableReference.localizedDescription); return }
        returnZonesToDesktop(reason: "preview-reference")
        let window = previewWindow ?? PreviewWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        if let old = window.contentView as? QLPreviewView { old.close() }
        guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 620), style: .normal) else { return }
        preview.previewItem = url as NSURL; window.contentView = preview
        window.title = L("预览 · ", "Preview · ") + url.lastPathComponent; window.isReleasedWhenClosed = false
        if previewWindow == nil { window.center() }; previewWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func showHistory() {
        if let historyWindow { NSApp.activate(ignoringOtherApps: true); historyWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Pan's Desktop · 操作记录", "Pan's Desktop · Activity History"); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(app: self)); historyWindow = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func remove(_ path: String, _ id: UUID) {
        do {
            try store.remove(path, from: id)
            if selectedZone == id { setSelection(selectedPaths, in: id) }
            hideHover(); revision += 1
        }
        catch { alert(L("保存失败", "Unable to Save"), error.localizedDescription) }
    }
    func transfer(_ path: String, from source: UUID, to destination: UUID) {
        do { try store.transfer(path, from: source, to: destination); revision += 1 }
        catch { alert(L("无法转移引用", "Unable to Transfer References"), error.localizedDescription) }
    }
    func openReference(_ path: String, in id: UUID, reveal: Bool = false) {
        guard let url = store.resolvedURL(path, in: id) else {
            refreshReferences(); alert(L("原文件暂不可用", "Original File Unavailable"), StoreFailure.unavailableReference.localizedDescription); return
        }
        returnZonesToDesktop(reason: reveal ? "reveal-reference" : "open-reference")
        if let openReferenceTestHook { openReferenceTestHook(url, reveal); return }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { trace("open-reference-request " + url.lastPathComponent); let accepted = NSWorkspace.shared.open(url); trace("open-reference-dispatched accepted=\(accepted)") }
        refreshReferences()
    }
    @objc func refreshReferences() {
        guard let store, !referenceRefreshRunning, !referenceDragInProgress, !fileOperationRunning else { return }
        referenceRefreshRunning = true
        let snapshot = store.zones, root = store.root, allowPersonalFiles = store.allowPersonalFiles
        referenceQueue.async { [weak self] in
            let result = ReferenceStore.refreshed(snapshot, root: root, allowPersonalFiles: allowPersonalFiles)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.referenceRefreshRunning = false
                guard !self.referenceDragInProgress, !self.fileOperationRunning else { return }
                do {
                    if try self.store.applyRefresh(result, basedOn: snapshot) {
                        self.revision += 1
                        self.trace("references-refreshed unavailable=\(result.unavailable.count)")
                    }
                } catch { self.trace("references-refresh-save-failed") }
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { keepApplicationAvailable(); finishDesktopRevealIfReady(); if started { refreshReferences() } }
    func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pendingDesktopReveal, !NSApp.isActive else { return }
            self.returnZonesToDesktop(reason: "app-resigned")
        }
    }
    func highlightDrop(_ id: UUID?, target: GridDropTarget? = nil) {
        hoveredZone = id
        for view in dropViews.allObjects {
            view.layer?.borderWidth = view.zoneID == id ? 1.5 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            view.guide.target = view.zoneID == id ? target : nil
            view.guide.needsDisplay = true
        }
    }
    func trace(_ text: String) {
        traceQueue.async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clearzones-desktop-drag-events.log")
            let data = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
            else { try? data.write(to: url) }
        }
    }
    @objc func showTrial() {
        for panel in panels.values { panel.orderOut(nil) }
        if let trialWindow { NSApp.activate(ignoringOtherApps: true); trialWindow.makeKeyAndOrderFront(nil); return }
        let window = TrialWindow(contentRect: NSRect(x: 80, y: 230, width: 1248, height: 390), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Pan's Desktop · 示例文件篮", "Pan's Desktop · Sample File Basket")
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.controller = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.22, alpha: 1)
        let content = NSView(); window.contentView = content
        let label = NSTextField(labelWithString: L("只使用示例文件：收纳方式会移动文件，可撤销；仅引用方式保留原路径。", "Samples only: Collect mode moves files and supports undo. Reference mode keeps originals in place."))
        label.textColor = .white; label.font = .systemFont(ofSize: 12); label.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(label)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12; row.alignment = .top; row.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(row)
        let basket = NSHostingView(rootView: TestBasket(app: self)); row.addArrangedSubview(basket)
        basket.widthAnchor.constraint(equalToConstant: 294).isActive = true
        basket.heightAnchor.constraint(equalToConstant: 316).isActive = true
        for zone in store.zones.prefix(3) {
            let hosting = NSHostingView(rootView: ZoneView(app: self, id: zone.id, layoutControls: false))
            let box = DropContainer(app: self, zoneID: zone.id, hosting: hosting); row.addArrangedSubview(box)
            box.widthAnchor.constraint(equalToConstant: 294).isActive = true
            box.heightAnchor.constraint(equalToConstant: 316).isActive = true
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 15)])
        trialWindow = window; window.level = .normal
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func focusZone(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        showInFront(); panels[id]?.makeKeyAndOrderFront(nil)
    }
    func add(_ urls: [URL], to id: UUID, from source: UUID? = nil) {
        do { try store.add(urls, to: id, from: source); revision += 1 }
        catch { alert(L("无法添加引用", "Unable to Add Reference"), error.localizedDescription) }
    }
    @objc func addZone() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PartitionPlacement.next(toRightOf: store.zones, on: ZoneFrame(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height))
        let zone = Zone(title: L("新分区", "New Partition"), x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        store.zones.append(zone); persist()
        do { _ = try storage.folder(zone.id) } catch { alert(L("收纳目录未准备好", "Storage Folder Not Ready"), error.localizedDescription) }
        makePanel(zone); revision += 1
        if preview { panels[zone.id]?.level = .normal }
        installMenu()
    }
    func deletePartition(_ id: UUID) {
        guard !referenceDragInProgress, !fileOperationRunning,
              let current = store.zones.first(where: { $0.id == id }) else { return }
        do { try partitionArchive.validateRemoval(id, from: store) }
        catch { alert(L("暂不能删除分区", "Partition Cannot Be Deleted Yet"), error.localizedDescription); return }
        let empty = current.paths.isEmpty
        let dialog = NSAlert()
        dialog.messageText = L("删除“\(current.title)”分区？", "Delete partition “\(current.title)”?")
        dialog.informativeText = empty
            ? L("这个分区已没有项目，只删除空分区框。已经移到桌面或其他分区的文件保持不变。\n\n可以通过“恢复上次删除的分区”恢复。", "This partition has no entries. Only the empty partition frame will be removed. Files already moved to the desktop or other partitions stay in place.\n\nUse Restore Last Deleted Partition to restore it.")
            : L("分区中有 \(current.paths.count) 个原文件暂不可用的条目。只移除分区框和这些记录，不删除、移动或修改原文件。\n\n可以通过“恢复上次删除的分区”恢复分区和记录。", "This partition contains \(current.paths.count) entries whose original files are unavailable. Only the frame and these records will be removed. Original files will not be deleted, moved, or modified.\n\nUse Restore Last Deleted Partition to restore the partition and records.")
        dialog.addButton(withTitle: empty ? L("删除空分区", "Delete Empty Partition") : L("删除分区与失效记录", "Delete Partition and Unavailable Entries"))
        dialog.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        do {
            try partitionArchive.remove(id, from: store)
            hideHover()
            // Detach hosted views before publishing the removal so they cannot
            // render a zone ID which is no longer in the active configuration.
            if let window = trialWindow { window.orderOut(nil); window.contentView = nil; window.close(); trialWindow = nil }
            if let panel = panels.removeValue(forKey: id) { panel.delegate = nil; panel.orderOut(nil); panel.contentView = nil; panel.close() }
            if selectedZone == id { selectedZone = nil; selectedPath = nil; selectedPaths = [] }
            revision += 1; installMenu(); trace("partition-deleted file-operations=none")
        } catch { alert(L("未删除分区", "Partition Was Not Deleted"), error.localizedDescription) }
    }
    @objc func restorePartition() {
        guard !referenceDragInProgress, !fileOperationRunning else { return }
        do {
            guard let restored = try partitionArchive.restore(in: store) else { return }
            makePanel(restored); revision += 1; installMenu(); refreshReferences()
            trace("partition-restored file-operations=none")
        } catch { alert(L("无法恢复分区", "Unable to Restore Partition"), error.localizedDescription) }
    }
    func logDesktopWindows(_ action: String) {
        for zone in store.zones {
            guard let p = panels[zone.id] else { continue }
            trace("window-state \(action) title=\(zone.title) window=\(p.windowNumber) frame=\(p.frame) level=\(p.level.rawValue) visible=\(p.isVisible) activeSpace=\(p.isOnActiveSpace) occlusion=\(p.occlusionState.rawValue) nonactivating=\(p.styleMask.contains(.nonactivatingPanel)) mainCapable=\(p.canBecomeMain) locked=\(zone.locked) movable=\(p.isMovable)")
        }
    }
    @objc func showInFront() {
        hideHover()
        trialWindow?.orderOut(nil); preview = true; showing = true
        desktopFocusMode = true
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        for p in panels.values { p.collectionBehavior = [.canJoinAllSpaces, .primary, .stationary, .ignoresCycle]; p.level = .normal; p.orderFrontRegardless() }
        panels.values.first(where: { $0.isVisible && $0.isOnActiveSpace })?.makeKeyAndOrderFront(nil)
        raiseExpandedPartitions()
        DispatchQueue.main.async { self.logDesktopWindows("front") }
    }
    // Only change our own window levels; never reorder an external document,
    // cancel a drag, or mutate file references when the user changes apps.
    func returnZonesToDesktop(reason: String) {
        pendingDesktopReveal = false
        desktopRevealGeneration += 1
        desktopFocusMode = false
        desktopFocusPanel = nil
        hideHover()
        let changed = preview || panels.values.contains { $0.level != desktopLevel }
        preview = false
        for panel in panels.values {
            panel.level = desktopLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        }
        trialWindow?.level = .normal
        keepApplicationAvailable()
        raiseExpandedPartitions()
        if changed || reason == "open-reference" || reason == "preview-reference" {
            trace("zones-returned-to-desktop reason=" + reason)
            logDesktopWindows(reason)
        }
    }
    @objc func backToDesktop() { trialWindow?.orderOut(nil); historyWindow?.orderOut(nil); previewWindow?.orderOut(nil); returnZonesToDesktop(reason: "desktop"); for p in panels.values { p.orderFrontRegardless() }; raiseExpandedPartitions(); DispatchQueue.main.async { self.logDesktopWindows("desktop") } }
    @objc func toggleShown() { showing.toggle(); for p in panels.values { if showing { p.orderFrontRegardless() } else { p.orderOut(nil) } }; if showing { raiseExpandedPartitions() } }
    @objc func openSamples() { returnZonesToDesktop(reason: "open-samples"); NSWorkspace.shared.open(sampleRoot) }
    @objc func help() { alert(L("Pan's Desktop · 收纳与引用", "Pan's Desktop · Collect and Reference"), L("收纳模式：主动拖入会移入收纳文件夹，只保留一份，可撤销或放回原位置。\n仅引用模式：原文件不动，适合脚本或自动化固定路径。\n\n每个分区可一键最大化／还原、收起、搜索、排序。\n双击标题改分区名；拖动标题移动。\n选中文件按空格快速预览，双击打开。\n\n已有引用不会自动收纳，外部改名或移动继续自动跟踪。", "Collect mode: Files dragged in are moved to the storage folder, keeping one copy. You can undo or return them to their original locations.\nReference mode: Original files stay in place, suitable for fixed paths used by scripts or automation.\n\nEach partition supports expand/restore, collapse, search, and sorting.\nDouble-click a title to rename the partition. Drag the title to move it.\nSelect a file and press Space to preview it, or double-click to open it.\n\nExisting references are not automatically collected. References continue to track external renames and moves.")) }
    @objc func quit() { NSApp.terminate(nil) }
    func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: L("好", "OK")); NSApp.activate(ignoringOtherApps: true); a.runModal() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        keepApplicationAvailable()
        DispatchQueue.main.async { [weak self] in self?.keepApplicationAvailable() }
        showInFront(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { desktopVisibility.restore(); referenceTimer?.invalidate(); if let workspaceActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver) }; if store != nil { persist() } }
}

// Only empty space starts a selection rectangle. File tiles, controls, the
// title bar, resize handle and scrolling continue receiving their own events.
final class SelectionSurface: NSView {
    weak var app: AppState?
    let zone: UUID
    let hosting: NSView
    var start = NSPoint.zero
    var rectangle: NSRect?
    var initial: Set<String> = []
    var additive = false
    init(app: AppState, zone: UUID, hosting: NSView) {
        self.app = app; self.zone = zone; self.hosting = hosting
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var area: NSRect { NSRect(x: 8, y: 28, width: max(0, bounds.width - 24), height: max(0, bounds.height - 76)) }
    var tiles: [ReferenceTileView] {
        app?.tileViews.allObjects.filter { $0.zone == zone && !$0.fileURLSource && $0.window === window && !$0.visibleRect.intersection($0.bounds).isEmpty } ?? []
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard area.contains(point), NSApp.currentEvent?.type != .scrollWheel else { return nil }
        if tiles.contains(where: { convert($0.visibleRect.intersection($0.bounds), from: $0).contains(point) }) { return nil }
        // NSView.hitTest takes a point in its superview's coordinates. The
        // SwiftUI hosting view is flipped; converting into it inverted the
        // search-row hit test and let the selection layer steal those clicks.
        var hit = hosting.hitTest(convert(point, to: hosting.superview))
        while let view = hit, view !== hosting {
            if view is NSControl || view is NSScroller { return nil }
            hit = view.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard let app else { return }
        app.hideHover(); window?.makeFirstResponder(self)
        app.traceDesktopInput("selection-start")
        start = convert(event.locationInWindow, from: nil)
        additive = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        initial = additive && app.selectedZone == zone ? app.selectedPaths : []
        app.setSelection(initial, in: zone)
        rectangle = NSRect(origin: start, size: .zero); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(area)
        rectangle = rect
        let selected = Set(tiles.filter { rect.intersects(convert($0.visibleRect.intersection($0.bounds), from: $0)) }.map(\.path))
        app?.setSelection(initial.union(selected), in: zone)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { rectangle = nil; needsDisplay = true; app?.traceDesktopInput("selection-end") }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 0, let app {
            app.setSelection(Set(tiles.first?.orderedPaths ?? app.zone(zone).paths), in: zone)
        } else if event.keyCode == 53 { app?.setSelection([], in: zone) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let rectangle, !rectangle.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); rectangle.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let line = NSBezierPath(rect: rectangle); line.lineWidth = 1; line.stroke()
    }
}

struct GridCellProbe: NSViewRepresentable {
    let app: AppState; let zone: UUID; let path: String
    func makeNSView(context: Context) -> GridCellView { let v = GridCellView(); configure(v); return v }
    func updateNSView(_ view: GridCellView, context: Context) { configure(view) }
    func configure(_ view: GridCellView) { view.zone = zone; view.path = path; app.gridCells.add(view) }
}
final class GridCellView: NSView {
    var zone = UUID(); var path = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class GridDropGuide: NSView {
    var target: GridDropTarget?
    var cells: [GridDropCell] = []
    var clip: CGRect = .zero
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let target else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        for cell in cells {
            let outline = NSBezierPath(roundedRect: cell.rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            outline.setLineDash([4, 4], count: 2, phase: 0); outline.lineWidth = 1; outline.stroke()
        }
        let slot = target.rect ?? NSRect(x: 14, y: clip.minY + 14, width: min(100, bounds.width - 28), height: GridDropLayout.rowHeight)
        let outline = NSBezierPath(roundedRect: slot.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        NSColor.controlAccentColor.withAlphaComponent(0.17).setFill(); outline.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke(); outline.lineWidth = 1.5; outline.stroke()
        if target.folderPath != nil {
            let badge = NSRect(x: slot.maxX - 30, y: slot.minY + 4, width: 26, height: 15)
            NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            (L("移入", "Move In") as NSString).draw(in: badge.insetBy(dx: 3, dy: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white])
            return
        }
        let x = target.trailing ? slot.maxX + 2 : slot.minX - 5
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: slot.minY + 4, width: 3, height: slot.height - 8), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
final class DropContainer: NSView {
    weak var app: AppState?
    let zoneID: UUID
    let hosting: NSView
    let guide = GridDropGuide()
    init(app: AppState, zoneID: UUID, hosting: NSView) {
        self.app = app; self.zoneID = zoneID; self.hosting = hosting
        let initialSize = NSSize(width: max(PartitionWindowLayout.minimumWidth, hosting.frame.width), height: max(180, hosting.frame.height))
        super.init(frame: NSRect(origin: .zero, size: initialSize))
        wantsLayer = true; layer?.cornerRadius = 18; app.dropViews.add(self)
        addSubview(hosting)
        let selection = SelectionSurface(app: app, zone: zoneID, hosting: hosting)
        selection.translatesAutoresizingMaskIntoConstraints = false; addSubview(selection)
        NSLayoutConstraint.activate([selection.leadingAnchor.constraint(equalTo: leadingAnchor), selection.trailingAnchor.constraint(equalTo: trailingAnchor), selection.topAnchor.constraint(equalTo: topAnchor), selection.bottomAnchor.constraint(equalTo: bottomAnchor)])
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor), hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor)])
        guide.translatesAutoresizingMaskIntoConstraints = false; addSubview(guide)
        NSLayoutConstraint.activate([guide.leadingAnchor.constraint(equalTo: leadingAnchor), guide.trailingAnchor.constraint(equalTo: trailingAnchor), guide.topAnchor.constraint(equalTo: topAnchor), guide.bottomAnchor.constraint(equalTo: bottomAnchor)])
        registerForDraggedTypes([NSPasteboard.PasteboardType(referenceType), .fileURL])
    }
    required init?(coder: NSCoder) { nil }
    func input(_ sender: NSDraggingInfo) -> (urls: [URL], source: UUID?, sourcePaths: [String]?, sessionID: UUID?)? {
        guard let app, !app.zone(zoneID).locked else { return nil }
        let pb = sender.draggingPasteboard
        if let data = pb.data(forType: NSPasteboard.PasteboardType(referenceType)) {
            guard let value = try? JSONDecoder().decode(ReferenceDrag.self, from: data),
                  app.store.zones.contains(where: { $0.id == value.zone && !$0.locked && !value.allPaths.isEmpty && value.allPaths.allSatisfy($0.paths.contains) }),
                  let urls = try? app.resolvedBatch(value.allPaths, in: value.zone) else { return nil }
            return (urls, value.zone, value.allPaths, value.sessionID)
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
              urls.allSatisfy({ $0.isFileURL && (try? app.store.validated($0)) != nil }) else { return nil }
        return (urls, nil, nil, nil)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        app?.trace("enter " + (app?.zone(zoneID).title ?? "") + " window=\(window?.windowNumber ?? -1) types=" + (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: ","))
        return proposed(sender)
    }
    func movesFile(_ value: (urls: [URL], source: UUID?, sourcePaths: [String]?, sessionID: UUID?)) -> Bool {
        guard let app, value.source != zoneID, app.zone(zoneID).usesStorage else { return false }
        return true
    }
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
    func insertion(_ sender: NSDraggingInfo, moving: [String], autoscroll: Bool = false) -> GridDropTarget {
        let point = convert(sender.draggingLocation, from: nil)
        var body = NSRect(x: 0, y: 26, width: bounds.width, height: max(0, bounds.height - 72))
        if let scroll = scrollView(in: hosting) {
            let clip = scroll.contentView
            body = convert(clip.bounds, from: clip)
            if autoscroll, let document = scroll.documentView {
                let p = clip.convert(sender.draggingLocation, from: nil)
                if clip.bounds.contains(p) {
                    let dy: CGFloat = p.y < clip.bounds.minY + 20 ? -12 : (p.y > clip.bounds.maxY - 20 ? 12 : 0)
                    let y = min(max(0, clip.bounds.minY + dy), max(0, document.bounds.height - clip.bounds.height))
                    if y != clip.bounds.minY { clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip) }
                }
            }
        }
        guide.clip = NSRect(x: body.minX, y: bounds.maxY - body.maxY, width: body.width, height: body.height)
        guide.cells = app?.gridCells.allObjects.compactMap { view in
            guard view.zone == zoneID, view.window === window, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
            let rect = convert(view.bounds, from: view)
            guard rect.intersects(body) else { return nil }
            return GridDropCell(path: view.path, rect: NSRect(x: rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height))
        } ?? []
        let p = CGPoint(x: point.x, y: bounds.maxY - point.y)
        var target = GridDropLayout.target(at: p, cells: guide.cells, order: app?.zone(zoneID).orderedPaths ?? [])
        if let app, let cell = guide.cells.first(where: { $0.rect.insetBy(dx: $0.rect.width * 0.22, dy: 9).contains(p) }),
           let folder = app.store.resolvedURL(cell.path, in: zoneID), !moving.contains(folder.path),
           (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            target = GridDropTarget(index: target.index, rect: cell.rect, trailing: false, folderPath: cell.path)
        }
        return target
    }
    func proposed(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let value = input(sender), let app else { self.app?.highlightDrop(nil); return [] }
        let target = insertion(sender, moving: value.urls.map(\.path), autoscroll: true)
        let physical = target.folderPath != nil || movesFile(value)
        let operation: NSDragOperation = physical || value.source != nil ? .move : .copy
        guard sender.draggingSourceOperationMask.contains(operation) else { app.highlightDrop(nil); return [] }
        if let folder = target.folderPath {
            guard app.storage.canMoveIntoFolder(value.urls, path: folder, in: zoneID, sourceZone: value.source) else { app.highlightDrop(nil); return [] }
        } else if physical {
            guard app.storage.canCollect(value.urls, to: zoneID, sourceZone: value.source) else { app.highlightDrop(nil); return [] }
        }
        app.highlightDrop(zoneID, target: target)
        return operation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { proposed(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { if app?.hoveredZone == zoneID { app?.highlightDrop(nil) } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { let valid = input(sender) != nil; app?.trace("prepare \(valid)"); return valid }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { app?.highlightDrop(nil) }
        guard let app, let value = input(sender) else { return false }
        do {
            let target = insertion(sender, moving: value.urls.map(\.path)), order = app.zone(zoneID).orderedPaths
            app.fileOperationRunning = true; defer { app.fileOperationRunning = false }
            if let folder = target.folderPath {
                _ = try app.storage.moveIntoFolder(value.urls, path: folder, in: zoneID, sourceZone: value.source)
            } else if value.source == zoneID, let paths = value.sourcePaths {
                _ = try app.storage.reorder(paths, in: zoneID, at: target.index, displayOrder: order)
            } else if movesFile(value) {
                _ = try app.storage.collect(value.urls, to: zoneID, at: target.index, displayOrder: order, sourceZone: value.source)
            } else if let source = value.source, let paths = value.sourcePaths {
                _ = try app.storage.transferReferences(paths, from: source, to: zoneID, at: target.index, displayOrder: order)
            } else { try app.store.add(value.urls, to: zoneID, at: target.index, displayOrder: order) }
            if let token = value.sessionID { app.handledDragSessions.insert(token) }
            app.revision += 1
            app.trace("drop-success " + app.zone(zoneID).title + " window=\(window?.windowNumber ?? -1) count=\(value.urls.count) insertion=\(target.index) sameZone=\(value.source == zoneID) intoFolder=\(target.folderPath != nil)")
            return true
        } catch {
            app.revision += 1; app.trace("drop-failed target=\(app.zone(zoneID).title) targetLocked=\(app.zone(zoneID).locked) source=\(value.source.map { app.zone($0).title } ?? "Finder") reason=\(error.localizedDescription)")
            DispatchQueue.main.async { app.alert(L("未完成拖入", "Drop Incomplete"), error.localizedDescription) }
            return false
        }
    }
}

// Alignment applies only to an intentional title drag. Existing layouts,
// startup, resizing and locked windows never pass through this helper.
enum PartitionAlignment {
    static let threshold: CGFloat = 12
    static func origin(for frame: NSRect, beside others: [NSRect]) -> NSPoint {
        let nearby = others.filter { frame.insetBy(dx: -threshold, dy: -threshold).intersects($0) }
        func nearest(_ offsets: [CGFloat]) -> CGFloat {
            offsets.filter { abs($0) <= threshold }.min { abs($0) < abs($1) } ?? 0
        }
        // Match top with top, never bottom with bottom.
        let dy = nearest(nearby.map { $0.maxY - frame.maxY })
        let positioned = frame.offsetBy(dx: 0, dy: dy)
        var xOffsets = nearby.map { $0.minX - frame.minX }
        for other in nearby where min(positioned.maxY, other.maxY) > max(positioned.minY, other.minY) {
            // Adjacent outer borders touch, with no extra padding or overlap.
            // This is adjacency, not right-edge alignment.
            xOffsets.append(other.maxX - frame.minX)
            xOffsets.append(other.minX - frame.maxX)
        }
        return NSPoint(x: frame.minX + nearest(xOffsets), y: frame.minY + dy)
    }
}

struct TitleDrag: NSViewRepresentable {
    let app: AppState; let id: UUID
    func makeNSView(context: Context) -> TitleDragView { let v = TitleDragView(); v.app = app; v.id = id; return v }
    func updateNSView(_ view: TitleDragView, context: Context) { view.app = app; view.id = id }
}
final class TitleDragView: NSView {
    weak var app: AppState?; var id = UUID()
    var origin = NSPoint.zero; var start = NSPoint.zero
    var gestureStarted = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let app, let window else { return }
        app.traceDesktopInput("title-down")
        gestureStarted = false
        if event.clickCount == 2 { app.rename(id); return }
        guard !app.zone(id).locked, !app.zone(id).isMaximized else { return }
        origin = window.frame.origin; start = window.convertPoint(toScreen: event.locationInWindow)
        gestureStarted = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard gestureStarted, let app, !app.zone(id).locked, !app.zone(id).isMaximized, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let proposed = NSRect(origin: NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y), size: window.frame.size)
        let neighbors = app.store.zones.compactMap { zone -> NSRect? in
            guard zone.id != id, let panel = app.panels[zone.id], panel.isVisible else { return nil }
            return panel.frame
        }
        window.setFrameOrigin(PartitionAlignment.origin(for: proposed, beside: neighbors))
    }
    override func mouseUp(with event: NSEvent) { gestureStarted = false; app?.traceDesktopInput("title-up") }
}
struct ResizeHandle: NSViewRepresentable {
    let locked: Bool
    var onHover: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ResizeView { let v = ResizeView(); configure(v); return v }
    func updateNSView(_ view: ResizeView, context: Context) { configure(view) }
    func configure(_ view: ResizeView) {
        view.locked = locked; view.onHover = onHover
        view.setAccessibilityLabel(L("调整分区大小", "Resize Partition"))
    }
}
final class ResizeView: NSView {
    var locked = false { didSet { if locked { gestureStarted = false } } }
    var origin = NSRect.zero; var start = NSPoint.zero
    var gestureStarted = false
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        gestureStarted = false
        guard !locked, let window else { return }
        origin = window.frame; start = window.convertPoint(toScreen: event.locationInWindow); gestureStarted = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard gestureStarted, !locked, let window else { return }; let p = window.convertPoint(toScreen: event.locationInWindow)
        let width = max(PartitionWindowLayout.minimumWidth, max(window.minSize.width, origin.width + p.x - start.x)); let height = max(180, origin.height - p.y + start.y)
        window.setFrame(NSRect(x: origin.minX, y: origin.maxY - height, width: width, height: height), display: true)
    }
    override func mouseUp(with event: NSEvent) { gestureStarted = false }
}
struct TileInteraction: NSViewRepresentable {
    let app: AppState; let zone: UUID; let path: String; let icon: NSImage
    var fileURLSource = false
    var orderedPaths: [String] = []
    func makeNSView(context: Context) -> ReferenceTileView { let v = ReferenceTileView(); configure(v); return v }
    func updateNSView(_ view: ReferenceTileView, context: Context) { configure(view) }
    func configure(_ view: ReferenceTileView) { view.app = app; view.zone = zone; view.path = path; view.icon = icon; view.fileURLSource = fileURLSource; view.orderedPaths = orderedPaths; app.tileViews.add(view) }
}
final class ReferenceTileView: NSView, NSDraggingSource {
    weak var app: AppState?; var zone = UUID(); var path = ""; var icon: NSImage?
    var dragging = false
    var mouseDownPoint = NSPoint.zero
    var clickCancelled = false
    var fileURLSource = false
    var hoverTrackingArea: NSTrackingArea?
    var exportsFileMove = false
    var moveItems: [FileMoveItem] = []
    var dragSessionID: UUID?
    var orderedPaths: [String] = []
    var pendingCommandToggle = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard !dragging, !fileURLSource, NSEvent.pressedMouseButtons == 0 else { return }
        app?.enterHover(self, at: NSEvent.mouseLocation)
    }
    override func mouseExited(with event: NSEvent) { app?.exitHover(self, at: NSEvent.mouseLocation) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { app?.hideHover(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !fileURLSource, let app {
            let fromTop = isFlipped ? local.y : bounds.height - local.y
            let missing = app.store.unavailable.contains(path)
            if fromTop >= bounds.height - 22 && missing { return nil }
        }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !fileURLSource else { return super.performKeyEquivalent(with: event) }
        let action: String?
        switch event.charactersIgnoringModifiers?.lowercased() { case "c": action = "copy"; case "d": action = "duplicate"; case "i": action = "info"; default: action = nil }
        if let action { executeFileAction(action); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, event.modifierFlags.contains(.command), !fileURLSource, let app {
            if app.store.resolvedURL(path, in: zone) == nil { app.remove(path, zone) }
            else { app.trashFile(path, in: zone) }
        } else if event.keyCode == 49, !fileURLSource { app?.previewReference(path, in: zone) }
        else if (event.keyCode == 36 || (event.keyCode == 125 && event.modifierFlags.contains(.command))), !fileURLSource { app?.openReference(path, in: zone) }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        app?.hideHover()
        window?.makeFirstResponder(self)
        app?.traceDesktopInput("file-down")
        if !fileURLSource, let app {
            let modifiers = event.modifierFlags.intersection([.command, .shift])
            pendingCommandToggle = modifiers == .command && app.selectedZone == zone && app.selectedPaths.contains(path)
            let preserve = pendingCommandToggle || (modifiers.isEmpty && app.selectedZone == zone && app.selectedPaths.contains(path) && app.selectedPaths.count > 1)
            if !preserve { app.selectFile(path, in: zone, modifiers: modifiers, order: orderedPaths) }
        }
        dragging = false; clickCancelled = false; mouseDownPoint = convert(event.locationInWindow, from: nil)
        app?.trace("source-down selection=\(app?.selectedPaths.count ?? 0) modifiers=\(event.modifierFlags.rawValue)")
    }
    override func mouseUp(with event: NSEvent) {
        if pendingCommandToggle, !dragging { app?.selectFile(path, in: zone, modifiers: .command, order: orderedPaths) }
        pendingCommandToggle = false
        guard !dragging, !clickCancelled else { app?.clickTracker.cancel(); return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if app?.clickTracker.released(key: zone.uuidString + path, time: event.timestamp, point: point, systemClicks: event.clickCount, modifiers: event.modifierFlags) == true {
            if fileURLSource { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { app?.openReference(path, in: zone) }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 7 else { return }
        clickCancelled = true; app?.clickTracker.cancel()
        app?.hideHover(); pendingCommandToggle = false
        var items: [NSDraggingItem] = []
        moveItems = []; exportsFileMove = false
        if fileURLSource {
            let pasteboard = NSPasteboardItem(); pasteboard.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            items = [NSDraggingItem(pasteboardWriter: pasteboard)]
        } else {
            guard let app, !app.zone(zone).locked else { return }
            let chosen = Set(app.actionPaths(path, in: zone))
            let paths = app.zone(zone).orderedPaths.filter(chosen.contains)
            do {
                let urls = try app.resolvedBatch(paths, in: zone)
                for url in urls { try app.storage.validateImport(url) }
                let token = UUID(); dragSessionID = token
                let payload = try JSONEncoder().encode(ReferenceDrag(zone: zone, path: paths[0], paths: paths, sessionID: token))
                moveItems = try urls.map { try FileMoveItem(source: $0, referenceData: payload) }
                items = moveItems.map { NSDraggingItem(pasteboardWriter: $0) }
                exportsFileMove = true
            } catch { dragSessionID = nil; app.alert(L("无法拖出所选文件", "Unable to Drag Out Selected Files"), error.localizedDescription); return }
        }
        guard !items.isEmpty else { return }
        dragging = true; app?.referenceDragInProgress = true
        app?.trace("source-drag files=\(items.count) window=\(window?.windowNumber ?? -1)")
        for (index, item) in items.enumerated() {
            let offset = Double(min(index, 3)) * 7
            item.setDraggingFrame(NSRect(x: point.x - 24 + offset, y: point.y - 24 - offset, width: 48, height: 48), contents: fileURLSource ? icon : app?.fileImage(moveItems[index].source.path))
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag(at: screenPoint, operation: operation)
    }
    func finishDrag(at screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; exportsFileMove = false; app?.referenceDragInProgress = false
        app?.highlightDrop(nil); app?.trace("source-end operation=\(operation.rawValue) count=\(moveItems.count) screen=(\(screenPoint.x),\(screenPoint.y))")
        let internalDrop = dragSessionID.flatMap { app?.handledDragSessions.remove($0) } != nil
        dragSessionID = nil
        if !internalDrop, operation.contains(.delete), let app {
            let items = moveItems
            app.performFileOperation { try FileActionEngine(store: app.store, storage: app.storage).finishTrashDrag(items, in: zone) }
        } else if operation.contains(.move), !internalDrop { for item in moveItems { app?.finishNativeMove(item, sourceZone: zone) } }
        // A copy or cancelled drag preserves every original and partition reference.
        moveItems = []
        if let app, app.selectedZone == zone { app.setSelection(app.selectedPaths, in: zone) }
        app?.refreshReferences()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if let app, !fileURLSource, app.zone(zone).locked { return [] }
        if context == .withinApplication { return [.copy, .move] }
        guard exportsFileMove, let app, !app.zone(zone).locked else { return [] }
        return [.copy, .move, .delete]
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { makeFileMenu() }
    @objc func runAction(_ sender: NSMenuItem) { if let operation = sender.representedObject as? String { executeFileAction(operation) } }

}
struct TestBasket: View {
    @ObservedObject var app: AppState
    var files: [URL] { Array(Set(app.store.zones.flatMap(\.paths).filter { $0.hasPrefix(app.sampleRoot.path + "/") })).sorted().map { URL(fileURLWithPath: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("示例文件篮", "Sample File Basket")).font(.system(size: 14, weight: .semibold)).padding(.top, 15)
            Text(L("拖到右侧 · 按分区方式处理", "Drag to a partition · Uses its import mode")).font(.system(size: 10)).opacity(0.65)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 12) {
                    ForEach(files, id: \.path) { url in
                        let icon = app.fileImage(url.path)
                        VStack(spacing: 6) {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 48, height: 44)
                            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(height: 28)
                        }.frame(maxWidth: .infinity).overlay { TileInteraction(app: app, zone: UUID(), path: url.path, icon: icon, fileURLSource: true) }
                    }
                }
            }
        }.padding(.horizontal, 12).foregroundStyle(.white).background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
    }
}
// Use a real control over the entire search row. SelectionSurface recognizes
// NSControl and lets clicks reach it instead of beginning a selection rectangle.
final class WideSearchField: NSSearchField {
    var requestsInitialFocus = true
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard requestsInitialFocus, let host = window else { return }
        requestsInitialFocus = false
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host, self.window === host else { return }
            self.focusForTyping()
        }
    }
    func focusForTyping() {
        guard let window else { return }
        // Keep search editing in the clicked partition without reopening
        // applications whose windows were hidden by the desktop interaction.
        window.makeKey()
        window.makeFirstResponder(self)
        (currentEditor() as? NSTextView)?.insertionPointColor = .white
    }
    override func mouseDown(with event: NSEvent) {
        focusForTyping()
        super.mouseDown(with: event)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let editArea = NSRect(x: 25, y: 0, width: max(0, bounds.width - 51), height: bounds.height)
        addCursorRect(editArea, cursor: .iBeam)
    }
}
struct ZoneSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> WideSearchField {
        let field = WideSearchField(frame: .zero)
        field.placeholderString = L("搜索本分区", "Search This Partition")
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.appearance = NSAppearance(named: .darkAqua)
        field.focusRingType = .exterior
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.stringValue = text
        field.setAccessibilityLabel(L("搜索本分区", "Search This Partition"))
        field.setAccessibilityHelp(L("点击输入框内的空白处即可输入，实时筛选本分区", "Click anywhere in the field to type and filter this partition instantly."))
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WideSearchField, context: Context) -> CGSize? {
        CGSize(width: max(1, proposal.width ?? 220), height: 38)
    }
    func updateNSView(_ field: WideSearchField, context: Context) {
        context.coordinator.text = $text
        // Do not reset the field editor while the user types or uses an IME.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing && field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { searchChanged(field) }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                (field.currentEditor() as? NSTextView)?.insertionPointColor = .white
            }
        }
        @objc func searchChanged(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}
enum PartitionHeaderLayout {
    static let height: CGFloat = 38
    static let titleSize: CGFloat = 13
    static let buttonSize: CGFloat = 34
    static func isNarrow(width: CGFloat) -> Bool { width < 240 }
    static func isCompact(width: CGFloat, title: String, count: Int, layoutControls: Bool) -> Bool {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .bold)
        let titleWidth = min(130, max(52, ceil((title as NSString).size(withAttributes: [.font: font]).width)))
        let countWidth = ceil((String(count) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) + 4
        let controls: CGFloat = layoutControls ? 5 : 3
        return width < 20 + controls * buttonSize + controls * 2 + titleWidth + countWidth
    }
}
// The complete visible hover box is part of the control label, so plain
// buttons and the menu accept clicks throughout the same enlarged rectangle.
struct HeaderButtonIcon: View {
    let symbol: String
    let hovered: Bool
    var iconFont: Font = .body
    var body: some View {
        Image(systemName: symbol).font(iconFont)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovered ? 0.16 : 0)))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hovered ? 0.12 : 0), lineWidth: 0.7).allowsHitTesting(false) }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: hovered)
    }
}
struct ControlHoverBackground: View {
    let hovered: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovered ? 0.16 : 0))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hovered ? 0.12 : 0), lineWidth: 0.7) }
            .allowsHitTesting(false)
    }
}
// A real 34-point control makes the complete hover background clickable,
// including the empty space around the lock symbol in a desktop panel.
struct HeaderLockButton: NSViewRepresentable {
    let app: AppState; let id: UUID; let locked: Bool
    var onHover: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> HeaderLockControl { let view = HeaderLockControl(); configure(view); return view }
    func updateNSView(_ view: HeaderLockControl, context: Context) { configure(view) }
    func configure(_ view: HeaderLockControl) {
        view.onToggle = { [weak app] in app?.lock(id) }
        view.onHover = onHover
        view.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        let label = locked ? L("解锁分区", "Unlock Partition") : L("锁定分区", "Lock Partition")
        view.setAccessibilityLabel(label)
        view.toolTip = locked ? L("点击解锁，允许移动分区和文件", "Unlock to move the partition and its files") : L("点击锁定，固定分区和文件", "Lock the partition and its files")
    }
}
final class HeaderLockControl: NSButton {
    var onToggle: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        title = ""; isBordered = false; bezelStyle = .regularSquare; imagePosition = .imageOnly
        contentTintColor = .white; focusRingType = .none
        target = self; action = #selector(toggleLock)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHover?(false) }
    @objc func toggleLock() { onToggle?() }
}
// Native menus can consume hover events before SwiftUI receives them.
// Track the menu rectangle without intercepting any clicks or menu actions.
struct MenuHoverTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(onHover: onHover) }
    func updateNSView(_ view: TrackingView, context: Context) { view.onHover = onHover }
    final class TrackingView: NSView {
        var onHover: (Bool) -> Void
        private var area: NSTrackingArea?
        init(onHover: @escaping (Bool) -> Void) { self.onHover = onHover; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let replacement = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self, userInfo: nil)
            addTrackingArea(replacement); area = replacement
        }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}
// A native menu measures its own text independently of the 34-point trigger
// and the partition width. Submenus receive the same full-label sizing.
enum PartitionMenuLayout {
    static func fit(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let font = menu.font ?? NSFont.menuFont(ofSize: 0)
        menu.font = font
        let widest = menu.items.filter { !$0.isSeparatorItem }.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        menu.minimumWidth = ceil(widest) + 64 // Checkmark, submenu arrow and margins.
        for item in menu.items { if let submenu = item.submenu { fit(submenu) } }
    }
}
final class PartitionMenuAction: NSMenuItem {
    let handler: () -> Void
    init(_ title: String, enabled: Bool = true, selected: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled; state = selected ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invoke() { if isEnabled { handler() } }
}
struct PartitionMenuButton: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    let onClose: () -> Void
    func makeNSView(context: Context) -> PartitionMenuControl { let view = PartitionMenuControl(); configure(view); return view }
    func updateNSView(_ view: PartitionMenuControl, context: Context) { configure(view) }
    func configure(_ view: PartitionMenuControl) { view.makeMenu = makeMenu; view.onClose = onClose }
}
final class PartitionMenuControl: NSButton {
    var makeMenu: (() -> NSMenu)?
    var onClose: (() -> Void)?
    private var presentedMenu: NSMenu?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        title = ""; isBordered = false; bezelStyle = .regularSquare; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        focusRingType = .none; target = self; action = #selector(openMenu)
        setAccessibilityRole(.popUpButton); setAccessibilityLabel(L("更多", "More")); toolTip = L("更多", "More")
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc func openMenu() {
        guard presentedMenu == nil, let menu = makeMenu?() else { return }
        PartitionMenuLayout.fit(menu); presentedMenu = menu
        DispatchQueue.main.async { [self] in
            if let window {
                let anchor = window.convertPoint(toScreen: convert(NSPoint(x: bounds.minX, y: bounds.minY), to: nil))
                // A view-attached popup can be compressed to its tiny parent
                // window. Screen coordinates detach it from that width limit.
                menu.popUp(positioning: nil, at: anchor, in: nil)
            }
            presentedMenu = nil; onClose?()
        }
    }
}
struct ZoneView: View {
    @ObservedObject var app: AppState
    let id: UUID
    var layoutControls = true
    @State private var searchVisible = false
    @State private var query = ""
    @State private var hoveredHeaderButton: String?
    @State private var hoveredResize = false
    func headerHover(_ key: String, _ inside: Bool) {
        if inside { hoveredHeaderButton = key }
        else if hoveredHeaderButton == key { hoveredHeaderButton = nil }
    }
    func files(_ z: Zone) -> [String] {
        z.orderedPaths.filter { query.isEmpty || URL(fileURLWithPath: $0).lastPathComponent.localizedStandardContains(query) }
    }
    var body: some View {
        GeometryReader { geometry in content(width: geometry.size.width) }
    }
    func content(width: CGFloat) -> some View {
        let z = app.zone(id)
        return VStack(spacing: 0) {
            header(z)
            if !z.isCollapsed || !layoutControls {
                if searchVisible {
                    ZoneSearchField(text: $query).frame(maxWidth: .infinity).frame(height: 38).padding(.horizontal, 12).padding(.top, 8)
                }
                ScrollView {
                    let displayed = files(z)
                    if displayed.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: query.isEmpty ? "tray.and.arrow.down" : "magnifyingglass").font(.system(size: 25, weight: .ultraLight))
                            Text(query.isEmpty ? L("拖入文档、图片或文件夹", "Drag in documents, images, or folders") : L("没有匹配的文件", "No matching files")).font(.system(size: 12))
                            Text(query.isEmpty ? (z.usesStorage ? L("移入收纳文件夹 · 只保留一份", "Move to storage · Keep one copy") : L("只添加引用 · 保留原路径", "Add references · Keep originals in place")) : L("试试文件名中的其他文字", "Try another part of the file name")).font(.system(size: 10)).opacity(0.7)
                        }.foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).padding(.top, 38)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(GridDropLayout.rowHeight), spacing: GridDropLayout.spacing, alignment: .top), count: GridDropLayout.columnCount(width: width)), alignment: .leading, spacing: GridDropLayout.spacing) {
                            ForEach(displayed, id: \.self) { path in fileTile(path) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(GridDropLayout.padding)
                    }
                }
                footer(z)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.75), radius: 1.5, x: 0, y: 1)
        .preferredColorScheme(.dark)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.025)))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color(white: 0.92).opacity(0.38), lineWidth: 1.0).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    func header(_ z: Zone) -> some View {
        GeometryReader { geometry in
            headerContent(z, compact: PartitionHeaderLayout.isCompact(width: geometry.size.width, title: z.title, count: z.paths.count, layoutControls: layoutControls), narrow: PartitionHeaderLayout.isNarrow(width: geometry.size.width), width: geometry.size.width)
        }.frame(height: PartitionHeaderLayout.height)
    }
    func toggleSearch(_ z: Zone) {
        searchVisible.toggle()
        if !searchVisible { query = "" }
        if z.isCollapsed { app.toggleCollapsed(id) }
    }
    func partitionMenu(compact: Bool, narrow: Bool) -> NSMenu {
        let z = app.zone(id)
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, selected: Bool = false, to parent: NSMenu? = nil, action: @escaping () -> Void) {
            (parent ?? menu).addItem(PartitionMenuAction(title, enabled: enabled, selected: selected, handler: action))
        }
        if narrow && layoutControls {
            add(z.isCollapsed ? L("展开分区", "Expand Partition") : L("收起分区", "Collapse Partition")) { app.toggleCollapsed(id) }
            add(z.isMaximized ? L("还原分区", "Restore Partition Size") : L("放大分区", "Expand Partition to Fit")) { app.toggleMaximum(id, itemCount: files(z).count, extraHeight: searchVisible ? 46 : 0) }
            menu.addItem(.separator())
        }
        if compact {
            add(L("本区共 \(z.paths.count) 项", "\(z.paths.count) items in this partition"), enabled: false) {}
            add(searchVisible ? L("关闭搜索", "Close Search") : L("搜索文件", "Search Files")) { toggleSearch(z) }
            menu.addItem(.separator())
        }
        add(L("添加文档、图片或文件夹", "Add Documents, Images, or Folders"), enabled: !z.locked) { app.chooseFiles(id) }
        let imports = NSMenu(title: L("拖入方式", "Import Mode"))
        add(L("收纳文件（移动，可撤销）", "Collect Files (Move, Undo Available)"), selected: z.usesStorage, to: imports) { app.change(id) { $0.organizeFiles = true } }
        add(L("仅添加引用（原路径不变）", "Add References Only (Keep Originals)"), selected: !z.usesStorage, to: imports) { app.change(id) { $0.organizeFiles = false } }
        let importItem = NSMenuItem(title: imports.title, action: nil, keyEquivalent: ""); importItem.submenu = imports; menu.addItem(importItem)
        let sorting = NSMenu(title: L("排序", "Sort By"))
        for (value, label) in [("manual", L("手动排列（拖动排序）", "Manual Order (Drag to Reorder)")), ("name", L("文件名称", "File Name")), ("modified", L("最近修改", "Last Modified")), ("type", L("文件类型", "File Type"))] {
            add(label, selected: (z.sortOrder ?? "manual") == value, to: sorting) { app.change(id) { $0.sortOrder = value } }
        }
        let sortItem = NSMenuItem(title: sorting.title, action: nil, keyEquivalent: ""); sortItem.submenu = sorting; menu.addItem(sortItem)
        add(L("打开本区收纳文件夹", "Open This Partition's Storage Folder")) { app.openZoneFolder(id) }
        menu.addItem(.separator())
        add(L("重命名分区", "Rename Partition")) { app.rename(id) }
        add(z.locked ? L("解锁分区（允许移动文件和分区）", "Unlock Partition (Allow Moving Files and Partition)") : L("锁定分区（固定位置与文件）", "Lock Partition (Fix Position and Files)")) { app.lock(id) }
        add(L("新增分区（向右排列）", "Add Partition to the Right")) { app.addZone() }
        add(z.paths.isEmpty ? L("删除空分区", "Delete Empty Partition") : L("删除分区", "Delete Partition")) { app.deletePartition(id) }
        add(L("恢复上次删除的分区", "Restore Last Deleted Partition"), enabled: app.partitionArchive.restorable(in: app.store) != nil) { app.restorePartition() }
        add(L("撤销上次操作", "Undo Last Action"), enabled: app.storage.undoRecord != nil) { app.undoStorage() }
        add(L("操作记录", "Activity History")) { app.showHistory() }
        add(L("放回桌面层", "Return to Desktop Layer")) { app.backToDesktop() }
        add(L("使用说明", "Help")) { app.help() }
        PartitionMenuLayout.fit(menu)
        return menu
    }
    func headerContent(_ z: Zone, compact: Bool, narrow: Bool, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            if layoutControls && !narrow {
                Button { app.toggleCollapsed(id) } label: {
                    HeaderButtonIcon(symbol: z.isCollapsed ? "chevron.right" : "chevron.down", hovered: hoveredHeaderButton == "collapse", iconFont: .system(size: 10, weight: .semibold))
                }.accessibilityLabel(z.isCollapsed ? L("展开分区", "Expand Partition") : L("收起分区", "Collapse Partition")).onHover { headerHover("collapse", $0) }.help(z.isCollapsed ? L("展开分区", "Expand Partition") : L("收起分区", "Collapse Partition"))
            }
            HStack(spacing: 4) {
                Text(z.title).font(.system(size: PartitionHeaderLayout.titleSize, weight: .bold)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                if !compact { Text("\(z.paths.count)").font(.system(size: 10)).opacity(0.55).fixedSize() }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 34).layoutPriority(1)
                .frame(width: narrow ? max(1, width - 20 - PartitionHeaderLayout.buttonSize - 2) : nil)
                .overlay { if layoutControls { TitleDrag(app: app, id: id) } }
                .help(z.title + "\n" + (z.locked ? (narrow ? L("分区已锁定，可在更多菜单中解锁", "Partition locked. Unlock it in the More menu.") : L("分区已锁定，点击右上角锁解锁后可拖动", "Partition locked. Use the upper-right lock to unlock and drag it.")) : L("拖动标题可自由移动分区", "Drag the title to move the partition")))
            if !compact {
                Button { toggleSearch(z) } label: {
                    HeaderButtonIcon(symbol: "magnifyingglass", hovered: hoveredHeaderButton == "search")
                }.accessibilityLabel(L("搜索文件", "Search Files")).onHover { headerHover("search", $0) }.help(L("搜索文件", "Search Files"))
            }
            if layoutControls && !narrow {
                Button { app.toggleMaximum(id, itemCount: files(z).count, extraHeight: searchVisible ? 46 : 0) } label: {
                    HeaderButtonIcon(symbol: z.isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", hovered: hoveredHeaderButton == "maximum", iconFont: .system(size: 11, weight: .medium))
                }.onHover { headerHover("maximum", $0) }.help(z.isMaximized ? L("还原分区", "Restore Partition Size") : L("按文件数量在原位置展开；文件已放得下时保持大小", "Expand here to fit the files. Keep the current size if they already fit."))
                    .accessibilityLabel(z.isMaximized ? L("还原分区", "Restore Partition Size") : L("放大分区", "Expand Partition to Fit"))
            }
            if !narrow {
                HeaderLockButton(app: app, id: id, locked: z.locked, onHover: { headerHover("lock", $0) })
                    .frame(width: 34, height: 34).contentShape(Rectangle())
                    .background { ControlHoverBackground(hovered: hoveredHeaderButton == "lock") }
                    .onHover { headerHover("lock", $0) }
            }
            PartitionMenuButton(makeMenu: { partitionMenu(compact: compact, narrow: narrow) }, onClose: { headerHover("menu", false) })
                .frame(width: 34, height: 34).onHover { headerHover("menu", $0) }
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hoveredHeaderButton == "menu" ? 0.16 : 0)))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hoveredHeaderButton == "menu" ? 0.12 : 0), lineWidth: 0.7).allowsHitTesting(false) }
                .background { MenuHoverTracker { headerHover("menu", $0) }.frame(width: 34, height: 34) }
        }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: PartitionHeaderLayout.height)
        .overlay(alignment: .bottom) { if !z.isCollapsed { Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5).padding(.horizontal, 12) } }
    }
    func footer(_ z: Zone) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 2)
            if app.selectedZone == id && app.selectedPaths.count > 1 { Text(L("已选 \(app.selectedPaths.count) 项", "\(app.selectedPaths.count) items selected")).foregroundStyle(.white).lineLimit(1).truncationMode(.tail) }

            Image(systemName: "line.3.horizontal.decrease").rotationEffect(.degrees(-45)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 26).contentShape(Rectangle())
                .background { ControlHoverBackground(hovered: hoveredResize) }
                .overlay { if layoutControls { ResizeHandle(locked: z.locked || z.isMaximized, onHover: { hoveredResize = $0 }).frame(width: 34, height: 26) } }
                .onHover { hoveredResize = $0 }
                .help(z.locked ? L("分区已锁定，请先解锁后调整大小", "Unlock this partition to resize it") : (z.isMaximized ? L("请先还原分区后调整大小", "Restore the partition before resizing it") : L("在灰白区域内按住拖动，可调整分区大小", "Drag anywhere in this area to resize the partition")))
        }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 14).frame(height: 26)
    }
    func fileTile(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let missing = app.store.unavailable.contains(path)
        let image = missing ? (NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: L("原文件暂不可用", "Original File Unavailable")) ?? NSImage()) : app.fileImage(path)
        let selected = app.selectedZone == id && app.selectedPaths.contains(path)
        let hovered = app.hoveredFile?.zone == id && app.hoveredFile?.path == path
        return VStack(spacing: 4) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 42).opacity(missing ? 0.55 : 1)
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center).frame(height: 29, alignment: .top)
        }.frame(maxWidth: .infinity).contentShape(Rectangle()).padding(.vertical, 3)
        // The transparent preview replaces these visuals, avoiding duplicate
        // text beneath the full name. The native mouse target stays unchanged.
        .opacity(hovered ? 0 : 1)
        .frame(height: GridDropLayout.rowHeight, alignment: .top)
        .background { GridCellProbe(app: app, zone: id, path: path) }
        .overlay { TileInteraction(app: app, zone: id, path: path, icon: image, orderedPaths: files(app.zone(id))) }
        .background(RoundedRectangle(cornerRadius: 9).fill(selected && !hovered ? Color.white.opacity(0.14) : .clear))
        .accessibilityHint(missing ? L("原文件暂不可用，引用已保留：", "Original file unavailable; reference kept: ") + path : path)
    }
}
// Draw only the icon and complete filename. No fill, material, border, or
// window shadow is used, and no line-count or truncation limit is applied.
final class FullNameHoverView: NSView {
    static let baseIconSize = NSSize(width: 44 * 1.3, height: 42 * 1.3)
    static let inset: CGFloat = 4
    let iconSize: NSSize
    let name: String
    let icon: NSImage
    let title: NSAttributedString
    let titleRect: NSRect
    override var isOpaque: Bool { false }
    init(name: String, icon: NSImage, availableSize: NSSize) {
        self.name = name; self.icon = icon
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 1.5; shadow.shadowOffset = NSSize(width: 0, height: -1)
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow
        ])
        title = text
        let maxWidth = max(1, availableSize.width - 2 * Self.inset)
        var width = min(maxWidth, Self.baseIconSize.width)
        func textHeight(_ width: CGFloat) -> CGFloat {
            ceil(text.boundingRect(with: NSSize(width: max(1, width), height: 10000),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        }
        var height = textHeight(width)
        func totalHeight(_ width: CGFloat, _ textHeight: CGFloat) -> CGFloat {
            width * 42 / 44 + 4 + 2 * Self.inset + textHeight
        }
        // Normal names grow downward at 1.3x icon size. Extremely long names
        // enlarge icon and text column together only when needed to fit a screen.
        // The title always has exactly the same width as its displayed icon.
        var candidate = width
        while totalHeight(width, height) > availableSize.height && candidate < maxWidth {
            candidate = min(maxWidth, candidate + 4)
            let candidateHeight = textHeight(candidate)
            if totalHeight(candidate, candidateHeight) < totalHeight(width, height) {
                width = candidate; height = candidateHeight
            }
        }
        iconSize = NSSize(width: width, height: width * 42 / 44)
        titleRect = NSRect(x: Self.inset, y: Self.inset, width: width, height: height)
        super.init(frame: NSRect(x: 0, y: 0, width: width + 2 * Self.inset, height: totalHeight(width, height)))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: NSRect(x: Self.inset,
                             y: bounds.height - Self.inset - iconSize.height,
                             width: iconSize.width, height: iconSize.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
struct HistoryView: View {
    @ObservedObject var app: AppState
    func label(_ state: String) -> String {
        ["done":L("已完成", "Completed"), "pending":L("待核对", "Pending Review"), "cancelled":L("已撤回", "Rolled Back"), "attention":L("需核对", "Needs Review") ][state] ?? state
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("操作记录", "Activity History")).font(.title2.bold())
                    Text(L("记录收纳、跨区移动、拖出、废纸篓和撤销；同名文件不覆盖。", "Tracks collection, transfers, drag-outs, Trash, and undo. Existing files are never overwritten.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("打开收纳文件夹", "Open Storage Folder")) { app.openStorage() }
                Button(L("撤销上次操作", "Undo Last Action")) { app.undoStorage() }.disabled(app.storage.undoRecord == nil)
            }
            Divider()
            if app.storage.records.isEmpty {
                VStack(spacing: 10) { Image(systemName: "clock.arrow.circlepath").font(.largeTitle); Text(L("还没有收纳操作", "No collection activity yet")); Text(L("拖入收纳分区后，可在这里查看原位置、目标位置和撤销。", "After collecting files, check original locations, destinations, and undo actions here.")).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(app.storage.records.reversed())) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(AppLanguage.historyTitle(record.title)).font(.headline)
                                    Text(label(record.state)).font(.caption).foregroundStyle(record.state == "attention" ? Color.orange : Color.secondary)
                                    Spacer()
                                    Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(Array(record.moves.enumerated()), id: \.offset) { _, move in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L("原位置：", "Original location: ") + move.from)
                                        Text(L("目标位置：", "Destination: ") + move.to)
                                    }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding(22).frame(minWidth: 620, minHeight: 360)
    }
}

func bootTrace(_ message: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clearzones-desktop-boot.log")
    let bytes = Data((message + "\n").utf8)
    if let file = try? FileHandle(forWritingTo: url) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: bytes) }
    else { try? bytes.write(to: url) }
}
bootTrace("entry " + Bundle.main.bundleURL.path)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
bootTrace("application-created")
let delegate = AppState()
bootTrace("delegate-created")
application.delegate = delegate
bootTrace("finish-launching")
application.finishLaunching()
delegate.startUI()
bootTrace("run")
application.run()
