import AppKit
import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw NSError(domain:message,code:1) } }
func rejected(_ label: String, _ action: () throws -> Void) throws {
 do { try action(); throw NSError(domain:"unexpected success "+label,code:1) }
 catch let e as NSError { if e.domain.hasPrefix("unexpected success") { throw e }; print("PASS: "+label) }
}
let fm=FileManager.default
let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:base,withIntermediateDirectories:false)
let desktop=base.appendingPathComponent("FixtureDesktop");try fm.createDirectory(at:desktop,withIntermediateDirectories:false)
let refs=try ReferenceStore(root:base.appendingPathComponent("TestFiles"),config:base.appendingPathComponent("Configuration/zones.json"),allowPersonalFiles:true)
refs.zones=[Zone(title:"A"),Zone(title:"B")];try refs.save()
let a=refs.zones[0].id,b=refs.zones[1].id
let engine=try StorageEngine(home:base,references:refs)
struct ItemSnapshot:Equatable {
 let inode:UInt64;let type:FileAttributeType;let bytes:Data?;let link:String?;let modified:Date;let mode:UInt16
 init(_ url:URL)throws {
  let v=try fm.attributesOfItem(atPath:url.path);inode=(v[.systemFileNumber] as! NSNumber).uint64Value;type=v[.type] as! FileAttributeType;modified=v[.modificationDate] as! Date;mode=(v[.posixPermissions] as! NSNumber).uint16Value
  bytes=type == .typeRegular ? try Data(contentsOf:url):nil
  link=type == .typeSymbolicLink ? try fm.destinationOfSymbolicLink(atPath:url.path):nil
 }
}
func tree(_ root:URL)throws->[String:ItemSnapshot] {
 var result=[".":try ItemSnapshot(root)]
 if let e=fm.enumerator(at:root,includingPropertiesForKeys:nil) {for case let u as URL in e {result[String(u.path.dropFirst(root.path.count+1))]=try ItemSnapshot(u)}}
 return result
}
let folder=desktop.appendingPathComponent("新建文件夹样本",isDirectory:true)
try fm.createDirectory(at:folder.appendingPathComponent("子文件夹/空文件夹"),withIntermediateDirectories:true)
let child=folder.appendingPathComponent("子文件夹/文档.txt");try Data("folder child original\n".utf8).write(to:child)
let image=folder.appendingPathComponent("图片.png");try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7V8AAAAASUVORK5CYII=")!.write(to:image)
try Data("hidden child\n".utf8).write(to:folder.appendingPathComponent(".hidden"))
try fm.createSymbolicLink(atPath:folder.appendingPathComponent("relative-link").path,withDestinationPath:"子文件夹/文档.txt")
let snapshot=try tree(folder);let identity=try FileIdentity(url:folder)
try refs.add([folder],to:a);try check(refs.zones[0].paths==[folder.path] && tree(folder)==snapshot,"reference-only folder import changed contents")
try refs.transfer(folder.path,from:a,to:b);try check(tree(folder)==snapshot && refs.zones[0].paths.isEmpty,"reference-only folder transfer changed folder")
try refs.remove(folder.path,from:b)
print("PASS: personal folder reference-only add/transfer/remove preserve complete tree")
try engine.collect([folder],to:a);let first=try engine.folder(a).appendingPathComponent(folder.lastPathComponent)
try check(!StorageEngine.exists(folder.path) && tree(first)==snapshot && FileIdentity(url:first)==identity,"folder collect duplicated or changed nested tree")
try engine.collect([first],to:b);let second=try engine.folder(b).appendingPathComponent(folder.lastPathComponent)
try check(!StorageEngine.exists(first.path) && tree(second)==snapshot,"folder cross-zone move changed contents")
try engine.moveOut(second,to:folder);try check(tree(folder)==snapshot && refs.zones.allSatisfy{$0.paths.isEmpty},"folder export failed")
try engine.undo();try check(tree(second)==snapshot && refs.zones[1].paths==[second.path],"folder export undo failed")
let drag=try FileMoveItem(source:second,referenceData:Data("folder payload".utf8))
try check(drag.pasteboardPropertyList(forType:.fileURL) as? String == second.absoluteString,"folder native drag URL missing")
try check(!engine.finishExternalMove(second,tracking:drag.tracking),"cancelled folder drag removed ref")
try StorageEngine.atomicMove(second,folder)
try check(engine.finishExternalMove(second,tracking:drag.tracking) && tree(folder)==snapshot && refs.zones.allSatisfy{$0.paths.isEmpty},"Finder folder completion failed")
try engine.undo();try engine.returnToOriginal(second);try check(tree(folder)==snapshot,"folder return to original changed tree")
print("PASS: folder collect/cross-zone/export/undo/native URL/cancel/Finder completion/return preserve all nested bytes, inodes, times, modes and links")
try refs.add([child],to:b);refs.zones[1].locked=true;try refs.save()
try engine.collect([folder],to:a)
try refs.refreshReferences()
try check(refs.zones[1].paths.count==1 && refs.resolvedURL(refs.zones[1].paths[0],in:b) != nil,"unrelated locked child reference was lost")
try engine.undo();try refs.refreshReferences()
try check(tree(folder)==snapshot,"independent folder move/undo changed contents")
print("PASS: unrelated locked child reference follows folder move and undo without blocking unlocked target")
refs.zones[1].locked=false;try refs.remove(child.path,from:b)
try engine.collect([folder],to:a)
refs.zones[0].locked=true;try refs.save()
try rejected("locked folder cannot move to Desktop") {_ = try engine.moveOut(first,to:folder,sourceZone:a)}
var recycled=false
try rejected("locked folder cannot reach Trash") {_ = try engine.trash(first,sourceZone:a,recycler:{u in recycled=true;return u})}
try check(!recycled && tree(first)==snapshot,"locked folder was modified")
refs.zones[0].locked=false;refs.zones[1].locked=true;try refs.save()
try rejected("folder cannot enter locked destination") {_ = try engine.collect([first],to:b)}
refs.zones[1].locked=false;try refs.save();try engine.returnToOriginal(first)
print("PASS: folder follows same source/destination lock rules as documents")
try rejected("parent plus child batch rejected before moving any item") {_ = try engine.collect([folder,child],to:a)}
try check(tree(folder)==snapshot && refs.zones.allSatisfy{$0.paths.isEmpty},"overlapping batch partially moved")
try rejected("moving folder into its own child is refused") {_ = try engine.plan(folder,folder.appendingPathComponent("子文件夹/循环"),after:[])}
try check(tree(folder)==snapshot,"self descendant refusal changed folder")
let target=try engine.folder(a).appendingPathComponent(folder.lastPathComponent);try fm.createDirectory(at:target,withIntermediateDirectories:false);try Data("keep".utf8).write(to:target.appendingPathComponent("keep.txt"));let targetBefore=try tree(target)
try rejected("same-name folder does not merge or overwrite") {_ = try engine.collect([folder],to:a)}
try check(tree(folder)==snapshot && tree(target)==targetBefore,"collision changed either folder")
try fm.removeItem(at:target) // Only the new collision fixture created immediately above.
let alias=desktop.appendingPathComponent("folder-alias");try fm.createSymbolicLink(at:alias,withDestinationURL:folder)
try rejected("folder symbolic link cannot physically collect target") {_ = try engine.collect([alias],to:a)}
try rejected("application-owned root cannot be moved into itself") {_ = try engine.collect([base],to:a)}
try rejected("actual Desktop root cannot be collected") {try engine.validateImport(fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))}
try check(tree(folder)==snapshot,"unsafe folder refusal changed sample")
print("PASS: recursive-target, nested-batch, same-name, symlink, app-root and Desktop-root protection")
let sampleTrash=base.appendingPathComponent("FakeTrash");try fm.createDirectory(at:sampleTrash,withIntermediateDirectories:false)
try engine.collect([folder],to:a)
try engine.trash(first,recycler:{u in let t=sampleTrash.appendingPathComponent(u.lastPathComponent);try StorageEngine.atomicMove(u,t);return t})
try check(tree(sampleTrash.appendingPathComponent(folder.lastPathComponent))==snapshot,"folder Trash changed tree")
try engine.undo();try check(tree(first)==snapshot,"folder Trash undo changed tree")
try engine.returnToOriginal(first)
print("PASS: folder reversible Trash and undo preserve complete tree")
if CommandLine.arguments.contains("--actual-desktop") {
 let real=fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Pan's Desktop文件夹验收-"+UUID().uuidString,isDirectory:true)
 try engine.collect([folder],to:a);try engine.moveOut(first,to:real)
 try check(tree(real)==snapshot && !StorageEngine.exists(first.path),"actual Desktop export failed")
 try engine.collect([real],to:b)
 let reimported=try engine.folder(b).appendingPathComponent(real.lastPathComponent)
 try check(!StorageEngine.exists(real.path) && tree(reimported)==snapshot,"actual Desktop reimport failed")
 try engine.moveOut(reimported,to:folder)
 try check(tree(folder)==snapshot && !StorageEngine.exists(real.path),"actual Desktop fixture not cleaned")
 print("PASS: actual Desktop new folder round-trip; no duplicate; fixture cleaned")
}
let looseDoc=desktop.appendingPathComponent("混合批量文档.txt")
let looseImage=desktop.appendingPathComponent("混合批量图片.png")
try Data("mixed document".utf8).write(to:looseDoc);try Data(contentsOf:image).write(to:looseImage)
let docBefore=try ItemSnapshot(looseDoc),imageBefore=try ItemSnapshot(looseImage)
let mixed=[folder,looseDoc,looseImage]
try engine.collect(mixed,to:a)
let mixedA=try mixed.map {try engine.folder(a).appendingPathComponent($0.lastPathComponent)}
try check(mixed.allSatisfy{!StorageEngine.exists($0.path)} && tree(mixedA[0])==snapshot,"mixed folder/document/image collection failed")
try engine.collect(mixedA,to:b)
let mixedB=try mixed.map {try engine.folder(b).appendingPathComponent($0.lastPathComponent)}
try engine.moveOut(mixedB,toDirectory:desktop)
try check(tree(folder)==snapshot && ItemSnapshot(looseDoc)==docBefore && ItemSnapshot(looseImage)==imageBefore && refs.zones.allSatisfy{$0.paths.isEmpty},"mixed export changed contents or retained references")
print("PASS: mixed folder/document/image batch collect, cross-zone and move-out preserve all items")
print("ALL FOLDER MODE TESTS PASSED")
