import AppKit
import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw NSError(domain:message,code:1) } }
let fm=FileManager.default
let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:base,withIntermediateDirectories:false)
let config=base.appendingPathComponent("Configuration/zones.json")
let refs=try ReferenceStore(root:base.appendingPathComponent("TestFiles"),config:config,allowPersonalFiles:true)
refs.zones=[Zone(title:"常用文件",organizeFiles:true),Zone(title:"临时文件",organizeFiles:true),Zone(title:"图片素材",organizeFiles:true),Zone(title:"待处理",organizeFiles:true)]
try refs.save()
let engine=try StorageEngine(home:base,references:refs)
let a=refs.zones[0].id,b=refs.zones[1].id
let desktop=base.appendingPathComponent("Desktop");try fm.createDirectory(at:desktop,withIntermediateDirectories:false)
let trash=base.appendingPathComponent("FakeTrash");try fm.createDirectory(at:trash,withIntermediateDirectories:false)
var results:[String]=[]
struct Snapshot: Equatable {
 let data:Data;let identity:FileIdentity;let modified:Date;let mode:UInt16
 init(_ url:URL)throws{data=try Data(contentsOf:url);identity=try FileIdentity(url:url);let attrs=try fm.attributesOfItem(atPath:url.path);modified=attrs[.modificationDate] as! Date;mode=(attrs[.posixPermissions] as! NSNumber).uint16Value}
}
func failure(_ name:String,_ body:()throws->Void)throws{do{try body();throw NSError(domain:"unexpected success "+name,code:1)}catch let e as NSError{if e.domain.hasPrefix("unexpected success"){throw e};results.append("PASS: "+name)}}
let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7V8AAAAASUVORK5CYII=")!
let sentinel=desktop.appendingPathComponent("untouched.txt");try Data("do not touch".utf8).write(to:sentinel);let sentinelBefore=try Snapshot(sentinel)
for (name,data) in [("document.txt",Data("move test".utf8)),("image.png",png)] {
 let original=desktop.appendingPathComponent(name);try data.write(to:original);let baseline=try Snapshot(original)
 // Existing duplicate references must disappear when the file is physically collected.
 try refs.add([original],to:a);try refs.add([original],to:b)
 try engine.collect([original],to:a);let first=try engine.folder(a).appendingPathComponent(name)
 try check(!StorageEngine.exists(original.path) && refs.zones[0].paths==[first.path] && refs.zones[1].paths.isEmpty,"Desktop -> zone retained source or duplicate reference")
 try check(Snapshot(first)==baseline,"collect modified bytes/identity/mtime/mode")
 try engine.collect([first],to:b);let second=try engine.folder(b).appendingPathComponent(name)
 try check(!StorageEngine.exists(first.path) && refs.zones[0].paths.isEmpty && refs.zones[1].paths==[second.path],"cross-zone retained old file/membership")
 try check(Snapshot(second)==baseline,"cross-zone changed original")
 let target=desktop.appendingPathComponent(name);try engine.moveOut(second,to:target)
 try check(!StorageEngine.exists(second.path) && refs.zones.allSatisfy{$0.paths.isEmpty} && Snapshot(target)==baseline,"move out left a duplicate or changed original")
 try engine.undo();try check(Snapshot(second)==baseline && refs.zones[1].paths==[second.path],"undo export failed")
 let item=try FileMoveItem(source:second,referenceData:Data("private reference".utf8))
 try check(item.pasteboardPropertyList(forType:.fileURL) as? String==second.absoluteString,"native move URL missing")
 try check(item.pasteboardPropertyList(forType:FileMoveItem.referenceType) as? Data==Data("private reference".utf8),"internal drag payload missing")
 // Cancelled / copy-only external drags may not remove any membership.
 try check(!engine.finishExternalMove(second,tracking:item.tracking),"unmoved file lost reference")
 try check(refs.zones[1].paths==[second.path],"cancelled drag removed reference")
 try StorageEngine.atomicMove(second,target) // Simulate only Finder's filesystem action.
 try check(engine.finishExternalMove(second,tracking:item.tracking),"external move reconciliation failed")
 try check(refs.zones.allSatisfy{$0.paths.isEmpty} && Snapshot(target)==baseline,"native move reconciliation changed file or retained references")
 try engine.undo();try check(Snapshot(second)==baseline && refs.zones[1].paths==[second.path],"undo native export failed")
 try refs.add([second],to:a)
 try engine.trash(second,recycler:{url in let to=trash.appendingPathComponent(url.lastPathComponent);try StorageEngine.atomicMove(url,to);return to})
 let trashed=trash.appendingPathComponent(name)
 try check(!StorageEngine.exists(second.path) && refs.zones.allSatisfy{$0.paths.isEmpty} && Snapshot(trashed)==baseline,"trash retained a duplicate or destroyed original")
 try engine.undo();try check(Snapshot(second)==baseline && refs.zones[0].paths==[second.path] && refs.zones[1].paths==[second.path],"undo trash failed to restore original and memberships")
 try refs.remove(second.path,from:a)
 try engine.moveOut(second,to:target)
 results.append("PASS: "+name+" Desktop -> zone -> zone -> Desktop; real moves, no duplicate, stable bytes/identity/metadata; native URL/payload; cancelled drag; Finder completion; reversible Trash; undo")
}
if CommandLine.arguments.contains("--native-trash") {
 let file=desktop.appendingPathComponent("Pan's Desktop废纸篓验收-"+UUID().uuidString+".txt");try Data("native Trash fixture only".utf8).write(to:file)
 let nativeBefore=try Snapshot(file);try engine.collect([file],to:a);let stored=try engine.folder(a).appendingPathComponent(file.lastPathComponent)
 try engine.trash(stored)
 let receipt=engine.records.last!.moves[0]
 try check(receipt.to.contains("/.Trash/") && !StorageEngine.exists(stored.path) && refs.zones.allSatisfy{$0.paths.isEmpty},"native Trash path or memberships incorrect")
 try check(Snapshot(URL(fileURLWithPath:receipt.to))==nativeBefore,"native Trash changed original")
 try engine.undo();try check(Snapshot(stored)==nativeBefore && refs.zones[0].paths==[stored.path],"native Trash undo failed")
 try engine.moveOut(stored,to:file)
 results.append("PASS: actual macOS Trash API and undo restore file identity/bytes/metadata and memberships")
}
if CommandLine.arguments.contains("--actual-desktop") {
 let actualDesktop=fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop",isDirectory:true)
 for (ext,data) in [("txt",Data("actual Desktop move fixture".utf8)),("png",png)] {
  let name="Pan's Desktop移动验收-"+UUID().uuidString+"."+ext
  let file=desktop.appendingPathComponent(name);try data.write(to:file,options:.withoutOverwriting);let actualBefore=try Snapshot(file)
  let target=actualDesktop.appendingPathComponent(name);try check(!StorageEngine.exists(target.path),"actual Desktop name exists")
  try engine.collect([file],to:a);let stored=try engine.folder(a).appendingPathComponent(name)
  try engine.moveOut(stored,to:target)
  try check(!StorageEngine.exists(stored.path) && refs.zones.allSatisfy{$0.paths.isEmpty} && Snapshot(target)==actualBefore,"actual Desktop export did not move exactly one file")
  try engine.collect([target],to:b);let imported=try engine.folder(b).appendingPathComponent(name)
  try check(!StorageEngine.exists(target.path) && refs.zones[1].paths==[imported.path] && Snapshot(imported)==actualBefore,"actual Desktop import left a duplicate")
  try engine.moveOut(imported,to:file)
  results.append("PASS: "+ext+" actual Desktop move-out and move-in: source absent, one identity/contents unchanged; Desktop fixture cleaned")
 }
}
// Batch plans are committed together: a collision must abort the entire group.
let group=(0..<3).map{desktop.appendingPathComponent("batch-"+String($0)+".txt")}
for (i,file) in group.enumerated(){try Data(("batch "+String(i)).utf8).write(to:file)}
let groupBefore=try group.map{try Snapshot($0)}
try engine.collect(group,to:a)
let groupA=try group.map{try engine.folder(a).appendingPathComponent($0.lastPathComponent)}
try check(group.allSatisfy{!StorageEngine.exists($0.path)} && refs.zones[0].paths.count==3,"batch import retained source")
let payload=try JSONEncoder().encode(ReferenceDrag(zone:a,path:groupA[0].path,paths:groupA.map(\.path)))
let decoded=try JSONDecoder().decode(ReferenceDrag.self,from:payload)
try check(decoded.allPaths==groupA.map(\.path),"multi-drag payload lost selection")
try engine.collect(groupA,to:b)
let groupB=try group.map{try engine.folder(b).appendingPathComponent($0.lastPathComponent)}
try check(refs.zones[0].paths.isEmpty && refs.zones[1].paths.count==3 && groupA.allSatisfy{!StorageEngine.exists($0.path)},"batch cross-zone retained source")
try Data("existing target".utf8).write(to:group[1])
try failure("one collision aborts whole three-file batch"){_ = try engine.moveOut(groupB,toDirectory:desktop)}
try check(groupB.allSatisfy{StorageEngine.exists($0.path)} && refs.zones[1].paths.count==3 && !StorageEngine.exists(group[0].path) && !StorageEngine.exists(group[2].path),"batch collision partially moved files")
try fm.removeItem(at:group[1]) // Only this test's just-created collision fixture.
try engine.moveOut(groupB,toDirectory:desktop)
for (i,file) in group.enumerated(){try check(Snapshot(file)==groupBefore[i],"batch export changed identity/contents/metadata")}
try check(refs.zones.allSatisfy{$0.paths.isEmpty} && groupB.allSatisfy{!StorageEngine.exists($0.path)},"batch export left memberships or files")
try engine.undo();try check(refs.zones[1].paths.count==3 && group.allSatisfy{!StorageEngine.exists($0.path)},"batch export undo failed")
try engine.moveOut(groupB,toDirectory:desktop)
results.append("PASS: three-file batch import, transfer, export, undo and collision rollback; complete multi-item native payload")
// An existing Desktop reference needs no physical move when explicitly returned there.
let legacy=desktop.appendingPathComponent("legacy.txt");try Data("legacy".utf8).write(to:legacy);let legacyBefore=try Snapshot(legacy)
try refs.add([legacy],to:a);try engine.moveOut(legacy,to:legacy)
try check(refs.zones.allSatisfy{$0.paths.isEmpty} && Snapshot(legacy)==legacyBefore,"same-path export changed file")
try engine.undo();try check(refs.zones[0].paths==[legacy.path] && Snapshot(legacy)==legacyBefore,"same-path export undo failed")
try refs.remove(legacy.path,from:a)
results.append("PASS: existing Desktop reference returned without duplicate; undo restores membership")
let doc=desktop.appendingPathComponent("collision.txt");try Data("source".utf8).write(to:doc);try engine.collect([doc],to:a);let managed=try engine.folder(a).appendingPathComponent(doc.lastPathComponent);let before=try Snapshot(managed)
try Data("keep target".utf8).write(to:doc);let targetBefore=try Snapshot(doc)
try failure("same-name export preserves both originals"){_ = try engine.moveOut(managed,to:doc)}
try check(Snapshot(managed)==before && Snapshot(doc)==targetBefore && refs.zones[0].paths==[managed.path],"collision damaged original")
let broken=desktop.appendingPathComponent("broken.txt");try fm.createSymbolicLink(atPath:broken.path,withDestinationPath:desktop.appendingPathComponent("missing").path)
try failure("broken symlink target not overwritten"){_ = try engine.moveOut(managed,to:broken)}
let originalZones=refs.zones
try failure("Trash failure preserves file and memberships"){_ = try engine.trash(managed,recycler:{_ in throw NSError(domain:"test recycle failed",code:1)})}
try check(Snapshot(managed)==before && refs.zones==originalZones,"Trash failure damaged source")
// Fail the final journal write and require rollback from Trash.
var writes=0
let rollbackEngine=try StorageEngine(home:base,references:refs,writer:{data,url in writes += 1;if writes==3{throw NSError(domain:"injected final save failure",code:1)};try data.write(to:url,options:.atomic)})
try failure("final journal failure rolls Trash back without losing file"){_ = try rollbackEngine.trash(managed,recycler:{url in let to=trash.appendingPathComponent("rollback.txt");try StorageEngine.atomicMove(url,to);return to})}
try check(Snapshot(managed)==before && refs.zones==originalZones,"failed final journal lost file or refs")
try check(Snapshot(sentinel)==sentinelBefore,"unrelated file touched")
let reloaded=try ReferenceStore(root:refs.root,config:config,allowPersonalFiles:true);try check(reloaded.zones==refs.zones,"persistence changed memberships")
results.append("PASS: unrelated document untouched; saved zones reload exactly")
let out=try JSONSerialization.data(withJSONObject:["results":results,"fixture_root":base.path,"scope":"production storage and native writer core; Finder mouse gesture separate"],options:[.prettyPrinted,.sortedKeys]);try out.write(to:base.appendingPathComponent("results.json"));print(String(data:out,encoding:.utf8)!)
