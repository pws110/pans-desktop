import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ label:String) throws {if try !value(){throw NSError(domain:label,code:1)}}
let fm=FileManager.default
let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:base,withIntermediateDirectories:false)
let samples=base.appendingPathComponent("TestFiles");try fm.createDirectory(at:samples,withIntermediateDirectories:false)
let desktop=base.appendingPathComponent("FixtureDesktop");try fm.createDirectory(at:desktop,withIntermediateDirectories:false)
let store=try ReferenceStore(root:samples,config:base.appendingPathComponent("Configuration/zones.json"),allowPersonalFiles:true)
store.zones=[Zone(title:"源分区",x:123,y:456),Zone(title:"目标分区")];try store.save()
let a=store.zones[0].id,b=store.zones[1].id
let storage=try StorageEngine(home:base,references:store)
let archive=try PartitionArchive(url:base.appendingPathComponent("Configuration/deleted-partitions.json"))
let doc1=samples.appendingPathComponent("新建文档A.txt"),doc2=samples.appendingPathComponent("新建文档B.txt"),folder=samples.appendingPathComponent("新建文件夹")
try Data("fixture A".utf8).write(to:doc1);try Data("fixture B".utf8).write(to:doc2);try fm.createDirectory(at:folder,withIntermediateDirectories:false)
try Data("nested fixture".utf8).write(to:folder.appendingPathComponent("子文档.txt"))
let identities=try [doc1,doc2,folder,folder.appendingPathComponent("子文档.txt")].map{try FileIdentity(url:$0)}
try store.add([doc1,doc2,folder],to:a)
func refused(_ id:UUID,_ expected:Int,_ label:String)throws{
 let before=store.zones,config=try Data(contentsOf:store.config),entries=archive.entries.count
 do{try archive.remove(id,from:store);throw NSError(domain:"unexpected deletion",code:1)}
 catch PartitionDeletionError.notEmpty(let count){try check(count==expected,label+" wrong count")}
 try check(store.zones==before && Data(contentsOf:store.config)==config && archive.entries.count==entries,label+" changed configuration")
 print("PASS: "+label)
}
try refused(a,3,"nonempty zone refused before any archive/config write")
store.zones[0].locked=true;try store.save();try refused(a,3,"locked nonempty zone also refused")
store.zones[0].locked=false;try store.save()
try storage.collect([doc1],to:b,sourceZone:a)
try refused(a,2,"partial transfer to another zone still blocks deletion")
try storage.moveOut([doc2],toDirectory:desktop,sourceZone:a)
try refused(a,1,"partial Desktop move still blocks deletion")
try storage.collect([folder],to:b,sourceZone:a)
let empty=store.zones.first{$0.id==a}!
try check(empty.paths.isEmpty,"source not empty")
try archive.remove(a,from:store)
try check(!store.zones.contains{$0.id==a},"empty source not deleted")
let targetDoc=try storage.folder(b).appendingPathComponent(doc1.lastPathComponent)
let targetFolder=try storage.folder(b).appendingPathComponent(folder.lastPathComponent)
let desktopDoc=desktop.appendingPathComponent(doc2.lastPathComponent)
let current=[targetDoc,desktopDoc,targetFolder,targetFolder.appendingPathComponent("子文档.txt")]
try check(current.enumerated().allSatisfy{(try? FileIdentity(url:$0.element))==identities[$0.offset]},"deleting empty zone changed moved identities")
try check(Data(contentsOf:targetDoc)==Data("fixture A".utf8) && Data(contentsOf:desktopDoc)==Data("fixture B".utf8) && Data(contentsOf:current[3])==Data("nested fixture".utf8),"deleting empty zone changed moved contents")
print("PASS: fully cleared source deletes; files on Desktop and target partition retain bytes and identities")
try refused(b,2,"destination holding moved items cannot be deleted")
let loaded=try ReferenceStore(root:samples,config:store.config,allowPersonalFiles:true)
let reopened=try PartitionArchive(url:archive.url)
let restored=try reopened.restore(in:loaded)
try check(restored==empty && loaded.zones.first{$0.id==a}?.paths.isEmpty==true,"empty restore lost frame or resurrected old memberships")
print("PASS: restoration restores empty frame, leaves moved files in their destinations")
// An unavailable-only zone may be archived without touching a file.
let missing=Zone(title:"失效引用仍非空",paths:[samples.appendingPathComponent("absent.txt").path])
store.zones.append(missing);try store.save();try archive.remove(missing.id,from:store)
try check(!store.zones.contains{$0.id==missing.id} && archive.entries.last?.zone==missing,"missing-only archive lost records")
try check(try archive.restore(in:store)==missing,"missing-only restore lost original zone")
print("PASS: unavailable-only zone deletes and restores without touching files")
let refA=Zone(title:"引用源",organizeFiles:false),refB=Zone(title:"引用目标",organizeFiles:false)
store.zones.append(contentsOf:[refA,refB]);try store.add([desktopDoc],to:refA.id)
try refused(refA.id,1,"reference-only nonempty zone also refused")
try store.transfer(desktopDoc.path,from:refA.id,to:refB.id)
try archive.remove(refA.id,from:store)
try check(FileIdentity(url:desktopDoc)==identities[1] && store.zones.first{$0.id==refB.id}?.paths==[desktopDoc.path],"reference transfer deletion changed original")
print("PASS: reference-only transfer clears source and permits deleting only empty frame")
// Model the confirmation race: an initially empty zone receives a drop before
// deletion commits. The archive entry point must check the current model.
let race=Zone(title:"确认期间收到新项目");store.zones.append(race);try store.add([desktopDoc],to:race.id)
try refused(race.id,1,"new item arriving before commit prevents deletion")
print("ALL EMPTY-ONLY PARTITION TESTS PASSED; only new test fixtures used")
