import Foundation
func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let fm=FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let file=root.appendingPathComponent("全新测试文档.txt")
try Data("删除分区不能删除或移动此测试原件".utf8).write(to:file,options:.withoutOverwriting)
let original=try Data(contentsOf:file), attrs=try fm.attributesOfItem(atPath:file.path)
let config=root.appendingPathComponent("Configuration/zones.json")
let store=try ReferenceStore(root:root,config:config,allowPersonalFiles:true)
store.zones=[Zone(title:"A"),Zone(title:"待处理"),Zone(title:"C")]
try store.add([file],to:store.zones[1].id)
let archiveURL=root.appendingPathComponent("Configuration/deleted-partitions.json")
let archive=try PartitionArchive(url:archiveURL)
let populated=store.zones
do {try archive.remove(populated[1].id,from:store);fatalError("nonempty partition deleted")}
catch PartitionDeletionError.notEmpty(let count) {check(count==1 && store.zones==populated && archive.entries.isEmpty,"nonempty refusal changed state")}
check(!fm.fileExists(atPath:archiveURL.path),"nonempty refusal wrote archive")
try store.remove(file.path,from:populated[1].id)
let before=store.zones, removed=before[1]
try archive.remove(removed.id,from:store)
check(store.zones==[before[0],before[2]],"wrong partition removed")
check(try Data(contentsOf:file)==original,"original bytes changed")
let after=try fm.attributesOfItem(atPath:file.path)
for k in [FileAttributeKey.systemFileNumber,.size,.creationDate,.modificationDate,.posixPermissions] {check(String(describing:attrs[k])==String(describing:after[k]),"original metadata changed")}
let loaded=try ReferenceStore(root:root,config:config,allowPersonalFiles:true)
let reopened=try PartitionArchive(url:archiveURL)
check(reopened.restorable(in:loaded)?.zone==removed,"archive did not survive relaunch")
try reopened.restore(in:loaded)
check(loaded.zones==before,"restore lost ID, references, order or settings")
check(try reopened.restore(in:loaded)==nil,"restored zone duplicated")
print("PASS: nonempty partition refused without writes; empty partition removed/restored across relaunch with exact ID/order/settings; test original untouched")
for z in Array(loaded.zones) {try reopened.remove(z.id,from:loaded)}
check(loaded.zones.isEmpty,"last partition removal failed")
let empty=try ReferenceStore(root:root,config:config,allowPersonalFiles:true)
check(empty.zones.isEmpty,"empty active configuration not persisted")
while reopened.restorable(in:empty) != nil {try reopened.restore(in:empty)}
check(Set(empty.zones.map(\.id))==Set(before.map(\.id)),"restore after delete-all lost a partition")
print("PASS: delete-all/empty configuration persistence and repeated restore; originals preserved")
let failingArchive=try PartitionArchive(url:root.appendingPathComponent("blocked-archive.json"),writer:{_,_ in throw NSError(domain:"fixture",code:1)})
let current=store.zones
 do {try failingArchive.remove(current[0].id,from:store);fatalError("archive failure accepted")} catch {check(store.zones==current,"archive failure changed active zones")}
let blocked=root.appendingPathComponent("not-a-folder");try Data("blocked".utf8).write(to:blocked)
let failingStore=try ReferenceStore(root:root,config:blocked.appendingPathComponent("zones.json"),allowPersonalFiles:true);failingStore.zones=[removed]
 do {try archive.remove(removed.id,from:failingStore);fatalError("configuration failure accepted")} catch {check(failingStore.zones==[removed],"configuration failure lost partition")}
check(try PartitionArchive(url:archiveURL).entries.contains{$0.zone==removed},"durable backup lost on failed configuration save")
print("PASS: archive-write failure and active-config-write failure retain complete partition; durable recovery snapshot preserved")
let broken=root.appendingPathComponent("corrupt-archive.json");let invalid=Data("invalid".utf8);try invalid.write(to:broken)
 do {_=try PartitionArchive(url:broken);fatalError("corrupt archive accepted")} catch {check(try Data(contentsOf:broken)==invalid,"corrupt archive overwritten")}
print("PASS: corrupt archive refused without overwriting; all tests use only newly created fixture files")

let screen=ZoneFrame(x:0,y:0,width:1440,height:900)
let leftZone=Zone(title:"已有分区",x:18,y:602,width:300,height:280)
let next=PartitionPlacement.next(toRightOf:[leftZone],on:screen)
check(next.x==336 && next.y==602,"new partition did not extend right")
let edge=Zone(title:"右边缘",x:1100,y:602,width:300,height:280)
let wrapped=PartitionPlacement.next(toRightOf:[edge],on:screen)
check(wrapped.x==18 && wrapped.y<edge.y,"right-edge wrap failed")
let shifted=PartitionPlacement.next(toRightOf:[Zone(title:"外接屏",x:-1400,y:300,width:300,height:280)],on:ZoneFrame(x:-1440,y:-200,width:1440,height:900))
check(shifted.x == -1082 && shifted.y==300,"negative-screen coordinates failed")
print("PASS: new partitions extend right, wrap to next row at right edge, and support negative display coordinates without modifying existing frames")
