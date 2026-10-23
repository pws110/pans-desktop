import Foundation
func check(_ c:@autoclosure()throws->Bool,_ label:String)throws{if try !c(){throw NSError(domain:label,code:1)};print("PASS: "+label)}
func blocked(_ label:String,_ f:()throws->Void)throws{do{try f();throw NSError(domain:"unexpected success "+label,code:1)}catch StoreFailure.lockedZone{print("PASS: "+label)}}
let fm=FileManager.default,base=URL(fileURLWithPath:CommandLine.arguments[1]),fixtures=URL(fileURLWithPath:CommandLine.arguments[2])
try fm.createDirectory(at:base,withIntermediateDirectories:false)
let desktop=base.appendingPathComponent("FixtureDesktop");try fm.createDirectory(at:desktop,withIntermediateDirectories:false)
let refs=try ReferenceStore(root:base.appendingPathComponent("TestFiles"),config:base.appendingPathComponent("Configuration/zones.json"),allowPersonalFiles:true)
refs.zones=(0..<6).map{Zone(title:"独立分区\($0+1)")};let a=refs.zones[0].id,b=refs.zones[1].id,c=refs.zones[2].id
let excel=desktop.appendingPathComponent("新建Excel.xlsx"),png=desktop.appendingPathComponent("新建图片.png"),txt=desktop.appendingPathComponent("新建文档.txt"),folder=desktop.appendingPathComponent("新建文件夹")
try Data(contentsOf:fixtures.appendingPathComponent("sample.xlsx")).write(to:excel)
try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7V8AAAAASUVORK5CYII=")!.write(to:png)
try Data("brand new independent lock sample\n".utf8).write(to:txt)
try fm.createDirectory(at:folder,withIntermediateDirectories:false);try Data("nested".utf8).write(to:folder.appendingPathComponent("子文件.txt"))
let all=[excel,png,txt,folder]
try refs.add(all,to:b)
for i in 1..<6{refs.zones[i].locked=true};try refs.save()
let engine=try StorageEngine(home:base,references:refs)
for f in all {
 let identity=try FileIdentity(url:f),data=f.hasDirectoryPath ? nil:try? Data(contentsOf:f)
 try check(engine.canCollect([f],to:a),"one unlocked destination accepts "+f.lastPathComponent+" while five others are locked")
 try engine.collect([f],to:a,at:0)
 let moved=try engine.folder(a).appendingPathComponent(f.lastPathComponent)
 try check(FileIdentity(url:moved)==identity && (data == nil || (try? Data(contentsOf:moved))==data),"outside import preserves identity/content: "+f.lastPathComponent)
 try check(refs.zones[1].locked && refs.zones[1].paths.contains(moved.path),"unrelated locked reference follows import without being removed")
 try engine.undo()
 try check(FileIdentity(url:f)==identity && refs.zones[1].paths.contains(f.path) && refs.zones[0].paths.isEmpty,"undo ignores unrelated locks and restores outside source")
}
try check(refs.zones.dropFirst().allSatisfy(\.locked),"never unlock unrelated partitions to make imports work")
// Cross-partition actions check only the two explicit partitions.
refs.zones[1].locked=false;try refs.save();try engine.collect([txt],to:a,at:0)
let storedA=try engine.folder(a).appendingPathComponent(txt.lastPathComponent)
refs.zones[2].locked=false;try refs.add([storedA],to:c);refs.zones[2].locked=true;try refs.save()
try engine.collect([storedA],to:b,at:0,sourceZone:a)
let storedB=try engine.folder(b).appendingPathComponent(txt.lastPathComponent)
try check(refs.zones[2].locked && refs.zones[2].paths==[storedB.path],"cross-zone move succeeds with an unrelated locked shared reference")
try engine.undo();try check(StorageEngine.exists(storedA.path),"cross-zone undo needs only its own source and destination")
refs.zones[0].locked=true;try refs.save()
try blocked("explicit locked source still blocks cross-zone move"){_ = try engine.collect([storedA],to:b,sourceZone:a)}
refs.zones[0].locked=false;refs.zones[1].locked=true;try refs.save()
try blocked("explicit locked target still blocks outside import"){_ = try engine.collect([png],to:b)}
try blocked("explicit locked target still blocks cross-zone move"){_ = try engine.collect([storedA],to:b,sourceZone:a)}
refs.zones[1].locked=false;try refs.save()
let targetFolder=desktop.appendingPathComponent("目标文件夹");try fm.createDirectory(at:targetFolder,withIntermediateDirectories:false)
try refs.add([targetFolder],to:b)
refs.zones[3].locked=false;try refs.add([targetFolder],to:refs.zones[3].id);refs.zones[3].locked=true;try refs.save()
try engine.moveIntoFolder([storedA],path:targetFolder.path,in:b,sourceZone:a)
let child=targetFolder.appendingPathComponent(txt.lastPathComponent)
try check(StorageEngine.exists(child.path) && refs.zones[2].paths==[child.path] && refs.zones[3].locked,"folder drop ignores unrelated file and folder references in locked partitions")
try engine.undo();try check(StorageEngine.exists(storedA.path),"folder undo works with unrelated partitions locked")
refs.zones[1].locked=true;try refs.save()
// Only A is unlocked again; its local file operations remain independent.
try engine.reorder([storedA.path],in:a,at:0)
let out=desktop.appendingPathComponent("导出文档.txt")
try engine.moveOut(storedA,to:out,sourceZone:a)
try check(StorageEngine.exists(out.path) && refs.zones[2].paths==[out.path],"move-out from unlocked A ignores unrelated locked reference")
try engine.undo()
let fakeTrash=base.appendingPathComponent("FakeTrash");try fm.createDirectory(at:fakeTrash,withIntermediateDirectories:false)
try engine.trash(storedA,sourceZone:a,recycler:{u in let to=fakeTrash.appendingPathComponent(u.lastPathComponent);try StorageEngine.atomicMove(u,to);return to})
try check(refs.zones[2].paths.count==1,"unrelated locked reference is retained during reversible Trash")
try engine.undo();try check(StorageEngine.exists(storedA.path),"Trash undo ignores unrelated locked partitions")
refs.zones[0].locked=true;try refs.save()
try blocked("explicit locked source blocks move-out"){_ = try engine.moveOut(storedA,to:out,sourceZone:a)}
try blocked("explicit locked source blocks Trash"){_ = try engine.trash(storedA,sourceZone:a)}
print("ALL INDEPENDENT PARTITION LOCK TESTS PASSED")
