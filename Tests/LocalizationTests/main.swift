import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let chinese = AppLanguage.usesChinese
require(L("保存", "Save") == (chinese ? "保存" : "Save"), "Language selection failed")
require(AppLanguage.byteCount(51) == (chinese ? ByteCountFormatter.string(fromByteCount: 51, countStyle: .file) : "51 bytes"), "File sizes must follow the interface language")
require(AppLanguage.isInboxTitle("待处理") && AppLanguage.isInboxTitle("Inbox"), "Inbox lookup must work across languages")
require(!AppLanguage.isInboxTitle("我的工作"), "Custom titles must not become Inbox")
require(AppLanguage.historyTitle("收纳至“我的工作”") == (chinese ? "收纳至“我的工作”" : "Collect into “我的工作”"), "History labels must preserve user titles")
require(AppLanguage.historyTitle("移到废纸篓：我的文档.txt") == (chinese ? "移到废纸篓：我的文档.txt" : "Move to Trash: 我的文档.txt"), "History labels must preserve file names")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pans-localization-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let original = folder.appendingPathComponent("我的原文件-用户姓名.txt")
let originalBytes = Data("unchanged original".utf8)
try originalBytes.write(to: original)
let config = folder.appendingPathComponent("Configuration/zones.json")
let store = try ReferenceStore(root: folder.appendingPathComponent("TestFiles"), config: config, allowPersonalFiles: true)
let customTitle = "我的工作分区 — Keep This Name"
let zone = Zone(title: customTitle, x: 31, y: 47, width: 280, height: 250, locked: true, organizeFiles: false)
store.zones = [zone]
try store.save()
let before = try Data(contentsOf: config)
let locked = StoreFailure.lockedZone.localizedDescription
require(locked.contains(chinese ? "分区已锁定" : "partition is locked"), "Lock error not translated")
let collision = StorageError.collision(original.lastPathComponent).localizedDescription
require(collision.contains(original.lastPathComponent), "Original file names must not be translated")
require(collision.contains(chinese ? "目标已有" : "destination already contains"), "Dynamic error not translated")
let unavailable = AppDataHomeError.unavailable.localizedDescription
require(unavailable.contains(chinese ? "找不到" : "could not be found"), "Startup error not translated")
let engine = try StorageEngine(home: folder, references: store)
require(engine.root.lastPathComponent == "收纳文件", "Storage path must remain language-independent")
require(store.zones[0].title == customTitle && store.zones[0].x == 31 && store.zones[0].locked, "Existing settings changed")
let afterConfig = try Data(contentsOf: config)
let afterOriginal = try Data(contentsOf: original)
require(afterConfig == before, "Translating interface text must not rewrite settings")
require(afterOriginal == originalBytes, "Original file changed")
print("Localization and data-preservation checks passed: \(chinese ? "Chinese" : "English")")
