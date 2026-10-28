import AppKit

extension AppState {
    func revealDesktopForInteraction(in clickedPanel: ZonePanel? = nil) {
        if let revealDesktopTestHook { backToDesktop(); revealDesktopTestHook(); return }
        if Bundle.main.object(forInfoDictionaryKey: "PansDesktopDisableAppHidingForTests") as? Bool == true { backToDesktop(); return }
        guard let focusPanel = clickedPanel ?? panels.values.first(where: { $0.isVisible && $0.isOnActiveSpace }) else { return }
        if !desktopVisibility.isActive && !pendingDesktopReveal {
            let front = NSWorkspace.shared.frontmostApplication
            desktopReturnApplication = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : lastExternalApplication
        }
        hideHover()
        trialWindow?.orderOut(nil); historyWindow?.orderOut(nil); previewWindow?.orderOut(nil)
        // Keep a normal application and primary window as the focus owner.
        // Desktop layering is restored independently when the user changes apps.
        desktopFocusMode = true
        desktopFocusPanel = focusPanel
        preview = true
        desktopRevealGeneration += 1
        let generation = desktopRevealGeneration
        pendingDesktopReveal = true
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        focusPanel.collectionBehavior = [.canJoinAllSpaces, .primary, .stationary, .ignoresCycle]
        focusPanel.level = .normal
        focusPanel.makeKeyAndOrderFront(nil)
        focusPanel.makeMain()
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        finishDesktopRevealIfReady()
        DispatchQueue.main.async { [weak self] in self?.finishDesktopRevealIfReady() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.pendingDesktopReveal, self.desktopRevealGeneration == generation else { return }
            self.finishDesktopRevealIfReady()
            if self.pendingDesktopReveal {
                self.trace("desktop-focus-timeout active=\(NSApp.isActive) hidden=\(NSApp.isHidden) key=\(focusPanel.isKeyWindow) main=\(focusPanel.isMainWindow) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
                self.returnZonesToDesktop(reason: "activation-not-granted")
            }
        }
    }
    func finishDesktopRevealIfReady() {
        guard pendingDesktopReveal, desktopFocusMode, NSApp.isActive,
              let focusPanel = desktopFocusPanel else { return }
        focusPanel.makeKeyAndOrderFront(nil)
        focusPanel.makeMain()
        guard NSApp.mainWindow === focusPanel, focusPanel.isKeyWindow else { return }
        pendingDesktopReveal = false
        let workspace = NSWorkspace.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targets = workspace.runningApplications.filter {
            DesktopRevealPolicy.shouldHide(bundle: $0.bundleIdentifier, regular: $0.activationPolicy == .regular,
                                           ownPID: ownPID, pid: $0.processIdentifier, hidden: $0.isHidden)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var ranks: [pid_t: Int] = [:]
        for (index, info) in windows.enumerated() {
            if let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ranks[pid] == nil { ranks[pid] = index }
        }
        let ordered = targets.sorted { (ranks[$0.processIdentifier] ?? Int.max) < (ranks[$1.processIdentifier] ?? Int.max) }
        let hidden = desktopVisibility.hide(ordered)
        NSApp.activate()
        trace("desktop-reveal-request targets=\(targets.count) accepted=\(hidden) captured=\(desktopVisibility.applications?.count ?? 0) active=\(NSApp.isActive) main=\(NSApp.mainWindow != nil) policy=\(NSApp.activationPolicy().rawValue)")
        // Observation only. Never repeat hiding after a later double-click opens
        // a document or the user deliberately switches to another application.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let remaining = workspace.runningApplications.filter {
                $0.processIdentifier != ownPID && $0.activationPolicy == .regular && !$0.isHidden
            }.compactMap(\.bundleIdentifier).sorted()
            self?.trace("desktop-reveal-complete visible-apps=" + remaining.joined(separator: ","))
        }
    }
    func restoreDesktopApplications() {
        guard desktopVisibility.isActive else { return }
        let front = desktopReturnApplication
        returnZonesToDesktop(reason: "restore-windows")
        let count = desktopVisibility.restore()
        if !desktopVisibility.isActive { desktopReturnApplication = nil }
        if let front, !front.isTerminated {
            NSApp.yieldActivation(to: front)
            _ = front.activate(options: [])
        }
        trace("desktop-restore-complete restored=\(count) retryPending=\(desktopVisibility.isActive)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.desktopVisibility.confirmRestoration()
            if !self.desktopVisibility.isActive { self.desktopReturnApplication = nil }
            self.trace("desktop-restore-confirmed remaining=\(self.desktopVisibility.applications?.count ?? 0)")
        }
    }
    var fileActions: FileActionEngine { FileActionEngine(store: store, storage: storage) }
    func renameReference(_ path: String, in zone: UUID) {
        do {
            guard let url = try fileActions.urls([path], in: zone).first else { return }
            let input = NSTextField(string: url.lastPathComponent); input.frame = NSRect(x: 0, y: 0, width: 350, height: 26)
            let dialog = NSAlert(); dialog.messageText = L("重新命名", "Rename")
            dialog.informativeText = L("这会修改实际文件名；分区引用会同步更新。", "This changes the actual file name and updates its partition references.")
            dialog.accessoryView = input; dialog.addButton(withTitle: L("保存", "Save")); dialog.addButton(withTitle: L("取消", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if dialog.runModal() == .alertFirstButtonReturn {
                dialog.window.makeFirstResponder(nil)
                performFileOperation { _ = try storage.renameFile(url, name: input.stringValue, sourceZone: zone) }
            }
        } catch { alert(L("无法重新命名", "Unable to Rename"), error.localizedDescription) }
    }
    func showFileInfo(_ path: String, in zone: UUID) {
        guard let url = store.resolvedURL(path, in: zone) else { alert(L("原文件暂不可用", "Original File Unavailable"), StoreFailure.unavailableReference.localizedDescription); return }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .typeIdentifierKey, .tagNamesKey])
            let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .short
            let size = values.isDirectory == true ? L("文件夹", "Folder") : ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
            let details = [L("名称：", "Name: ") + url.lastPathComponent, L("位置：", "Location: ") + url.deletingLastPathComponent().path,
                L("大小／类型：", "Size / type: ") + size + " · " + (values.typeIdentifier ?? "—"),
                L("创建：", "Created: ") + (values.creationDate.map(date.string) ?? "—"),
                L("修改：", "Modified: ") + (values.contentModificationDate.map(date.string) ?? "—"),
                L("标签：", "Tags: ") + (values.tagNames ?? []).joined(separator: ", ")].joined(separator: "\n\n")
            let dialog = NSAlert(); dialog.messageText = L("显示简介", "Get Info"); dialog.informativeText = details
            dialog.addButton(withTitle: L("好", "OK")); dialog.addButton(withTitle: L("在访达中显示", "Show in Finder"))
            NSApp.activate(ignoringOtherApps: true)
            if dialog.runModal() == .alertSecondButtonReturn { openReference(path, in: zone, reveal: true) }
        } catch { alert(L("无法显示简介", "Unable to Get Info"), error.localizedDescription) }
    }
    func editTags(_ paths: [String], in zone: UUID) {
        do {
            guard let first = try fileActions.urls(paths, in: zone).first else { return }
            let old = (try first.resourceValues(forKeys: [.tagNamesKey])).tagNames ?? []
            let input = NSTextField(string: old.joined(separator: ", ")); input.frame = NSRect(x: 0, y: 0, width: 350, height: 26)
            let dialog = NSAlert(); dialog.messageText = L("标签", "Tags"); dialog.informativeText = L("多个标签用逗号分隔。留空可移除标签。", "Separate tags with commas. Leave empty to remove tags.")
            dialog.accessoryView = input; dialog.addButton(withTitle: L("保存", "Save")); dialog.addButton(withTitle: L("取消", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if dialog.runModal() == .alertFirstButtonReturn {
                dialog.window.makeFirstResponder(nil)
                let names = input.stringValue.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                performFileOperation { try fileActions.tags(names, paths: paths, in: zone) }
            }
        } catch { alert(L("无法修改标签", "Unable to Edit Tags"), error.localizedDescription) }
    }
}

extension ReferenceTileView: NSServicesMenuRequestor {
    func makeFileMenu() -> NSMenu? {
        guard let app, !fileURLSource else { return nil }
        window?.makeFirstResponder(self); app.hideHover()
        if app.selectedZone != zone || !app.selectedPaths.contains(path) { app.setSelection([path], in: zone, anchor: path) }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ operation: String, to target: NSMenu? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = operation; item.isEnabled = enabled; (target ?? menu).addItem(item)
        }
        let unlocked = !app.zone(zone).locked
        let paths = app.actionPaths(path, in: zone)
        let urls = (try? app.fileActions.urls(paths, in: zone, unlocked: false)) ?? []
        let available = !urls.isEmpty
        add(L("打开", "Open"), "open", enabled: available)
        if let first = urls.first {
            let with = NSMenu(title: L("打开方式", "Open With"))
            for application in NSWorkspace.shared.urlsForApplications(toOpen: first) {
                add(FileManager.default.displayName(atPath: application.path), "openwith:" + application.path, to: with)
            }
            let item = NSMenuItem(title: with.title, action: nil, keyEquivalent: ""); item.submenu = with; menu.addItem(item)
        }
        add(L("快速查看（空格）", "Quick Look (Space)"), "preview", enabled: available)
        add(L("显示简介", "Get Info"), "info", enabled: available)
        add(L("在访达中显示", "Show in Finder"), "reveal", enabled: available)
        if unlocked && available {
            menu.addItem(.separator())
            add(L("重新命名…", "Rename…"), "rename", enabled: paths.count == 1)
            add(L("复制（生成副本）", "Duplicate"), "duplicate")
            add(L("压缩…", "Compress…"), "compress")
            add(L("制作替身", "Make Alias"), "alias")
            add(L("拷贝", "Copy"), "copy")
            let picker = NSSharingServicePicker(items: urls)
            app.sharingPickers.append(picker); app.sharingPickers = Array(app.sharingPickers.suffix(4))
            let share = picker.standardShareMenuItem; share.title = L("共享…", "Share…"); menu.addItem(share)
            if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: urls) { add(L("隔空传送…", "AirDrop…"), "airdrop") }
            let tags = NSMenu(title: L("颜色标签", "Color Tags"))
            for (name, number, color) in [(L("红色", "Red"), 6, NSColor.systemRed), (L("橙色", "Orange"), 7, .systemOrange), (L("黄色", "Yellow"), 5, .systemYellow), (L("绿色", "Green"), 2, .systemGreen), (L("蓝色", "Blue"), 4, .systemBlue), (L("紫色", "Purple"), 3, .systemPurple), (L("灰色", "Gray"), 1, .systemGray)] {
                add(name, "color:\(number):" + name, to: tags)
                tags.items.last?.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true }
            }
            add(L("移除颜色标签", "Remove Color Label"), "color:0:", to: tags)
            let tagItem = NSMenuItem(title: tags.title, action: nil, keyEquivalent: ""); tagItem.submenu = tags; menu.addItem(tagItem)
            add(L("标签…", "Tags…"), "tags")
            let quick = NSMenu(title: L("快速操作", "Quick Actions"))
            add(L("压缩为 ZIP", "Compress to ZIP"), "compress", to: quick)
            add(L("制作替身", "Make Alias"), "alias", to: quick)
            add(L("在访达中使用更多快速操作…", "More Quick Actions in Finder…"), "reveal", to: quick)
            let quickItem = NSMenuItem(title: quick.title, action: nil, keyEquivalent: ""); quickItem.submenu = quick; menu.addItem(quickItem)
            let services = NSMenu(title: L("服务", "Services"))
            let serviceItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: ""); serviceItem.submenu = services
            NSApp.servicesMenu = services; menu.addItem(serviceItem)
            menu.addItem(.separator())
            if let first = urls.first, app.storage.isManaged(first), app.storage.originalLocation(first) != nil { add(L("放回原位置", "Return to Original Location"), "return") }
            let destination = NSMenu(title: L("移到分区", "Move to Partition"))
            for other in app.store.zones where other.id != zone && !other.locked { add(other.title, other.id.uuidString, to: destination) }
            let moveItem = NSMenuItem(title: destination.title, action: nil, keyEquivalent: ""); moveItem.submenu = destination; moveItem.isEnabled = !destination.items.isEmpty; menu.addItem(moveItem)
            add(L("移到桌面（原分区不保留）", "Move to Desktop (Remove from Partition)"), "desktop")
            add(L("移到废纸篓（可恢复）", "Move to Trash (Recoverable)"), "trash")
        }
        if unlocked { add(available ? L("仅移除本区引用（不删除文件）", "Remove Reference Only (Keep File)") : L("移除失效条目（不删除原文件）", "Remove Unavailable Entry (Keep Original)"), "remove") }
        return menu
    }
    func executeFileAction(_ operation: String) {
        guard let app else { return }
        let readOnly = ["open", "preview", "reveal", "info"].contains(operation) || operation.hasPrefix("openwith:")
        guard readOnly || !app.zone(zone).locked else { return }
        let paths = app.actionPaths(path, in: zone)
        switch operation {
        case "open": for p in paths { app.openReference(p, in: zone) }
        case "preview": app.previewReference(path, in: zone)
        case "reveal": app.openReference(path, in: zone, reveal: true)
        case "info": app.showFileInfo(path, in: zone)
        case "rename": if paths.count == 1 { app.renameReference(path, in: zone) }
        case "duplicate": app.performFileOperation { _ = try app.fileActions.duplicate(paths, in: zone) }
        case "compress": app.performFileOperation { _ = try app.fileActions.compress(paths, in: zone) }
        case "alias": app.performFileOperation { _ = try app.fileActions.alias(paths, in: zone) }
        case "copy": app.performFileOperation { try app.fileActions.copyToPasteboard(paths, in: zone, pasteboard: .general) }
        case "tags": app.editTags(paths, in: zone)
        case "airdrop":
            if let urls = try? app.fileActions.urls(paths, in: zone), let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) { service.perform(withItems: urls) }
        case "return": app.returnOriginal(path, in: zone)
        case "desktop": app.moveToDesktop(path, in: zone)
        case "trash":
            app.performFileOperation { for url in try app.fileActions.urls(paths, in: zone) { _ = try app.storage.trash(url, sourceZone: zone) } }
        case "remove": for p in paths { app.remove(p, zone) }
        default:
            if operation.hasPrefix("openwith:"), let urls = try? app.fileActions.urls(paths, in: zone, unlocked: false) {
                app.returnZonesToDesktop(reason: "open-with")
                NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: String(operation.dropFirst(9))), configuration: NSWorkspace.OpenConfiguration())
            } else if operation.hasPrefix("color:") {
                let parts = operation.components(separatedBy: ":")
                guard parts.count == 3, let color = Int(parts[1]) else { return }
                app.performFileOperation {
                    let urls = try app.fileActions.urls(paths, in: zone)
                    let standard = Set(["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
                    for url in urls {
                        let old = (try url.resourceValues(forKeys: [.tagNamesKey])).tagNames ?? []
                        let names = old.filter { !standard.contains($0) } + (color == 0 ? [] : [parts[2]])
                        try app.fileActions.tags(names, color: color, paths: [url.path], in: zone)
                    }
                }
            } else if let destination = UUID(uuidString: operation), !app.zone(destination).locked {
                if let urls = try? app.resolvedBatch(paths, in: zone), app.zone(destination).usesStorage { app.importFiles(urls, to: destination, from: zone) }
                else { app.performFileOperation { try app.store.transfer(paths, from: zone, to: destination) } }
            }
        }
    }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let app, !app.zone(zone).locked, [.fileURL, .string, NSPasteboard.PasteboardType("NSFilenamesPboardType")].contains(sendType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let app, let urls = try? app.fileActions.urls(app.actionPaths(path, in: zone), in: zone) else { return false }
        pasteboard.clearContents(); let result = pasteboard.writeObjects(urls as [NSURL])
        if types.contains(.string) { pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
        if types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) { pasteboard.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) }
        return result
    }
}
