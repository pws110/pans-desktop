import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw NSError(domain: message, code: 1) } }
func blocked(_ name: String, _ operation: () throws -> Void) throws {
    do { try operation(); throw NSError(domain: "unexpected success: " + name, code: 1) }
    catch StoreFailure.lockedZone { print("PASS: " + name) }
}
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try fm.createDirectory(at: base, withIntermediateDirectories: false)
let samples = base.appendingPathComponent("TestFiles")
try fm.createDirectory(at: samples, withIntermediateDirectories: false)
let refs = try ReferenceStore(root: samples, config: base.appendingPathComponent("Configuration/zones.json"), allowPersonalFiles: true)
refs.zones = [Zone(title: "测试A"), Zone(title: "测试B")]
try refs.save()
let a = refs.zones[0].id, b = refs.zones[1].id
let engine = try StorageEngine(home: base, references: refs)
let original = samples.appendingPathComponent("新建锁定测试.txt")
let bytes = Data("Created solely for lock regression\n".utf8)
try bytes.write(to: original)
let identity = try FileIdentity(url: original)
try engine.collect([original], to: a)
let stored = URL(fileURLWithPath: refs.zones[0].paths[0])
refs.zones[0].locked = true; try refs.save()
let configBefore = try Data(contentsOf: refs.config)
let journalBefore = try Data(contentsOf: engine.journalURL)
try blocked("locked source blocks native collect into another zone") { _ = try engine.collect([stored], to: b, sourceZone: a) }
try blocked("locked source blocks move-out") { _ = try engine.moveOut(stored, to: original, sourceZone: a) }
try blocked("locked source blocks return to original") { _ = try engine.returnToOriginal(stored, sourceZone: a) }
var recyclerCalled = false
try blocked("locked source blocks Trash before recycler") { _ = try engine.trash(stored, sourceZone: a, recycler: { url in recyclerCalled = true; return url }) }
try blocked("locked membership blocks undo") { _ = try engine.undo() }
try blocked("locked source blocks reference transfer") { try refs.transfer(stored.path, from: a, to: b) }
try blocked("locked source blocks add-from transfer") { try refs.add([stored], to: b, from: a) }
try blocked("locked source blocks removing reference") { try refs.remove(stored.path, from: a) }
try check(!recyclerCalled && Data(contentsOf: stored) == bytes && FileIdentity(url: stored) == identity, "blocked operation touched original")
try check(Data(contentsOf: refs.config) == configBefore && Data(contentsOf: engine.journalURL) == journalBefore, "blocked operation changed configuration or journal")
print("PASS: blocked operations preserve bytes, identity, configuration and journal")
refs.zones[0].locked = false; refs.zones[1].locked = true; try refs.save()
try blocked("locked destination blocks physical collect") { _ = try engine.collect([stored], to: b) }
try blocked("locked destination blocks reference add") { try refs.add([stored], to: b) }
try blocked("locked destination blocks reference transfer") { try refs.transfer(stored.path, from: a, to: b) }
refs.zones[1].locked = false; try refs.save()
try refs.add([stored], to: b)
refs.zones[0].locked = true; try refs.save()
try engine.moveOut(stored, to: original, sourceZone: b)
try check(refs.zones[0].paths == [original.path] && refs.zones[1].paths.isEmpty && FileIdentity(url: original) == identity, "unrelated locked reference interfered or disappeared")
try engine.undo()
try check(refs.zones[0].paths == [stored.path] && refs.zones[1].paths == [stored.path], "undo depended on unrelated lock or lost shared references")
print("PASS: unrelated locked reference does not block unlocked source; reference tracks move and undo")
refs.zones[0].locked = false; try refs.save()
try engine.collect([stored], to: b)
let moved = URL(fileURLWithPath: refs.zones[1].paths[0])
try check(FileIdentity(url: moved) == identity && Data(contentsOf: moved) == bytes && !StorageEngine.exists(stored.path), "unlock did not restore physical move")
try engine.returnToOriginal(moved)
try check(FileIdentity(url: original) == identity && Data(contentsOf: original) == bytes, "unlock did not restore return")
print("PASS: unlock restores movement and return while preserving identity and content")
print("ALL LOCK MODE TESTS PASSED")
