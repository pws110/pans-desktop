import AppKit
import Foundation

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { guard try condition() else { fatalError(message) } }
    catch { fatalError(message + ": " + error.localizedDescription) }
}
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let headless = CommandLine.arguments.contains("--headless")
let useReceiver = CommandLine.arguments.contains("--receiver")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
if !headless { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited) }

struct Snapshot: Codable, Equatable {
    let data: Data
    let identity: FileIdentitySnapshot
    let size: UInt64
    let mode: UInt16
    let modified: Date
    let created: Date
    init(_ url: URL) throws {
        data = try Data(contentsOf: url)
        let a = try fm.attributesOfItem(atPath: url.path)
        identity = FileIdentitySnapshot(device: (a[.systemNumber] as! NSNumber).uint64Value, inode: (a[.systemFileNumber] as! NSNumber).uint64Value)
        size = (a[.size] as! NSNumber).uint64Value; mode = (a[.posixPermissions] as! NSNumber).uint16Value
        modified = a[.modificationDate] as! Date; created = a[.creationDate] as! Date
    }
}
struct FileIdentitySnapshot: Codable, Equatable { let device: UInt64; let inode: UInt64 }
let config = root.appendingPathComponent("Configuration/zones.json")
let zonesBefore = try JSONDecoder().decode([Zone].self, from: Data(contentsOf: config))
var copied: [URL] = []
var results: [String] = []

func expectFailure(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Unexpected success: " + label) }
    catch { results.append("PASS: " + label) }
}

for name in ["拖放测试-文档.txt", "拖放测试-图片.png"] {
    fputs("CHECK: " + name + "\n", stderr)
    let source = root.appendingPathComponent("TestFiles/" + name)
    let target = destination.appendingPathComponent(name)
    require(!StorageEngine.exists(target.path), "Test destination already exists; refusing to touch it")
    let before = try Snapshot(source)
    let zone = zonesBefore.first { $0.paths.contains(source.path) }!
    let payload = try JSONEncoder().encode(ReferenceDrag(zone: zone.id, path: source.path))
    require(try FileCopyPromise.make(source: source, referenceData: payload, locked: true) == nil, "Locked zone exposed copy promise")
    if headless {
        try FileCopyRequest(source: source).copy(to: target)
    } else {
    let promise = try FileCopyPromise.make(source: source, referenceData: payload, locked: false)!
    let pb = NSPasteboard(name: NSPasteboard.Name("com.andy.clearzones.copy-test." + UUID().uuidString))
    defer { pb.releaseGlobally() }
    require(pb.writeObjects([promise]), "Native pasteboard rejected copy promise")
    require(pb.data(forType: FileCopyPromise.referenceType) == payload, "Internal reference payload changed")
    require(!(pb.types ?? []).contains(.fileURL), "Original URL leaked to external receiver")
    require(!StorageEngine.exists(target.path), "Promise wrote before drop was accepted")
    guard let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], receivers.count == 1 else {
        fatalError("Native receiver cannot read promise; types=\(pb.types ?? [])")
    }
    let lock = NSLock()
    var done = false, received: URL?, failure: Error?
    let receiverQueue = OperationQueue()
    if useReceiver {
        receivers[0].receivePromisedFiles(atDestination: destination, options: [:], operationQueue: receiverQueue) { url, error in
            lock.lock(); received = url; failure = error; done = true; lock.unlock()
        }
    } else {
        // Test the exact delegate entry point independently of receiver delivery.
        promise.request.filePromiseProvider(promise, writePromiseTo: target) { error in
            lock.lock(); received = target; failure = error; done = true; lock.unlock()
        }
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        lock.lock(); let complete = done; lock.unlock()
        if complete { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    lock.lock(); let completed = done, resultURL = received, resultError = failure; lock.unlock()
    require(completed, "Native receiver timed out")
    if let resultError { throw resultError }
    require(resultURL?.path == target.path, "Receiver did not write the selected destination")
    }
    let after = try Snapshot(source), copy = try Snapshot(target)
    require(before == after, "Original bytes, inode, permissions or timestamps changed")
    require(copy.data == before.data && copy.identity != before.identity, "Destination is not an independent exact copy")
    let zonesAfter = try JSONDecoder().decode([Zone].self, from: Data(contentsOf: config))
    require(zonesAfter.map { ($0.id.uuidString, $0.paths) }.map { $0.0 + $0.1.joined() } == zonesBefore.map { ($0.id.uuidString, $0.paths) }.map { $0.0 + $0.1.joined() }, "References or memberships changed")
    require(zonesAfter.allSatisfy { !$0.usesStorage }, "Reference-only mode changed")
    copied.append(target)
    results.append("PASS: \(headless ? "production copy engine" : "native promise negotiation + delegate") → \(target.path); independent exact copy; original metadata/bytes and all zone references preserved; locked export refused")
}

let scratch = output.appendingPathComponent("edge-cases", isDirectory: true)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
let source = scratch.appendingPathComponent("original.txt"), rename = scratch.appendingPathComponent("renamed.txt")
try Data("original payload".utf8).write(to: source, options: .withoutOverwriting)
let original = try Snapshot(source), request = try FileCopyRequest(source: source)
let collision = scratch.appendingPathComponent("collision.txt")
try Data("keep existing target".utf8).write(to: collision, options: .withoutOverwriting)
let collisionBefore = try Snapshot(collision)
expectFailure("same-name target preserved") { try request.copy(to: collision) }
require(try Snapshot(collision) == collisionBefore, "Collision overwrote existing target")
expectFailure("same source/destination refused") { try request.copy(to: source) }
let broken = scratch.appendingPathComponent("broken.txt")
try fm.createSymbolicLink(atPath: broken.path, withDestinationPath: scratch.appendingPathComponent("missing").path)
expectFailure("broken symlink target preserved") { try request.copy(to: broken) }
expectFailure("unavailable destination leaves original intact") { try request.copy(to: scratch.appendingPathComponent("missing/out.txt")) }
require(try Snapshot(source) == original, "Failure modified original")
try fm.moveItem(at: source, to: rename) // This test's own disposable fixture only.
try Data("replacement must not be copied".utf8).write(to: source, options: .withoutOverwriting)
let movedCopy = scratch.appendingPathComponent("after-rename.txt")
try request.copy(to: movedCopy)
require(try Data(contentsOf: movedCopy) == original.data, "Promise bound to replacement instead of tracked original")
require(try Snapshot(rename) == original, "Rename-aware copy changed original")
results.append("PASS: source renamed and old path replaced; bookmark identity selected original")
require(try fm.contentsOfDirectory(atPath: scratch.path).allSatisfy { !$0.hasPrefix(".Pan's Desktop复制-") }, "Staging artifacts left behind")
results.append("PASS: private staging cleaned after successful and refused copies")

let record: [String: Any] = ["copied_test_files": copied.map(\.path), "results": results, "production_copy_engine": true, "native_promise_negotiation": !headless, "native_copy_delegate": !headless, "native_receiver_delivery": useReceiver, "physical_mouse_gesture": false]
try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-copy-results.json"), options: .atomic)
for line in results { print(line) }
