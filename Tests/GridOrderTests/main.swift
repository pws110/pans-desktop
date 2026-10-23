import Foundation
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { if try !condition() { throw NSError(domain:label,code:1) };print("PASS: "+label) }
func blocked(_ label:String,_ action:()throws->Void)throws{do{try action();throw NSError(domain:"unexpected success "+label,code:1)}catch let e as NSError{if e.domain.hasPrefix("unexpected success"){throw e};print("PASS: "+label)}}
try check(GridOrder.inserting(["b"],into:["a","b","c","d"],at:4)==["a","c","d","b"],"same-zone move to end adjusts gap after removal")
try check(GridOrder.inserting(["b","d"],into:["a","b","c","d","e"],at:3)==["a","c","b","d","e"],"multi-selection moves as one ordered group")
try check(GridOrder.inserting(["a","a"],into:["a","b"],at:0)==["a","b"],"duplicates and self-drop do not duplicate icons")
let order=["a","b","c","d","e","f","g","h","i"]
let cells=order.enumerated().map{GridDropCell(path:$0.element,rect:CGRect(x:14+Double($0.offset%3)*108,y:14+Double($0.offset/3)*132,width:100,height:122))}
try check(GridDropLayout.target(at:CGPoint(x:25,y:65),cells:cells,order:order).index==0,"left edge selects gap before first cell")
try check(GridDropLayout.target(at:CGPoint(x:108,y:65),cells:cells,order:order).index==1,"right half inserts after cell")
try check(GridDropLayout.target(at:CGPoint(x:24,y:150),cells:cells,order:order).index==3,"new row keeps complete grid index")
try check(GridDropLayout.target(at:CGPoint(x:25,y:800),cells:cells,order:order).index==9,"space below final row appends")
try check(GridDropLayout.target(at:CGPoint(x:25,y:150),cells:Array(cells.dropFirst(3)),order:order).index==3,"scrolled layout retains hidden leading items")
try check(GridDropLayout.target(at:CGPoint(x:0,y:0),cells:[],order:[]).index==0,"empty zone accepts first grid slot")
let fm=FileManager.default,base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try fm.createDirectory(at:base,withIntermediateDirectories:false)
let samples=base.appendingPathComponent("TestFiles");try fm.createDirectory(at:samples,withIntermediateDirectories:false)
let refs=try ReferenceStore(root:samples,config:base.appendingPathComponent("Configuration/zones.json"),allowPersonalFiles:true)
refs.zones=[Zone(title:"A"),Zone(title:"B")];try refs.save();let a=refs.zones[0].id,b=refs.zones[1].id
let engine=try StorageEngine(home:base,references:refs)
func newFile(_ name:String)throws->URL{let f=samples.appendingPathComponent(name);try Data(("new test "+name).utf8).write(to:f);return f}
let files=try ["c.txt","a.txt","b.txt","d.txt"].map(newFile)
let snapshots=try Dictionary(uniqueKeysWithValues:files.map{($0.path,(try FileIdentity(url:$0),try Data(contentsOf:$0)))})
try refs.add(files,to:a);let original=refs.zones
try engine.reorder([files[1].path],in:a,at:4)
try check(refs.zones[0].paths==[files[0].path,files[2].path,files[3].path,files[1].path] && engine.records.last?.moves.isEmpty==true,"in-zone reorder commits order only, without physical moves")
try engine.undo();try check(refs.zones==original,"undo restores exact order and prior sort mode")
refs.zones[0].sortOrder="name";try refs.save();let sorted=refs.zones[0].orderedPaths
try engine.reorder([files[0].path],in:a,at:0,displayOrder:sorted)
try check(refs.zones[0].paths==[files[0].path]+sorted.filter{$0 != files[0].path} && refs.zones[0].sortOrder=="manual","drag from automatic sort preserves visible order and switches to manual")
try engine.undo();try check(refs.zones[0].sortOrder=="name" && refs.zones[0].paths==original[0].paths,"undo restores automatic sort")
refs.zones[0].sortOrder="manual";try refs.save()
try refs.add([files[3]],to:b)
let beforeRefTransfer=refs.zones
try engine.transferReferences([files[1].path,files[2].path],from:a,to:b,at:0,displayOrder:refs.zones[1].paths)
try check(refs.zones[1].paths==[files[1].path,files[2].path,files[3].path],"reference-only cross-zone insertion preserves group order")
try engine.undo();try check(refs.zones==beforeRefTransfer,"undo reference-only insertion restores both zones without moving originals")
try engine.transferReferences([files[1].path,files[2].path],from:a,to:b,at:0,displayOrder:refs.zones[1].paths)
for f in files {let v=snapshots[f.path]!;try check(FileIdentity(url:f)==v.0 && Data(contentsOf:f)==v.1,"reference-only ordering leaves original "+f.lastPathComponent)}
let targetFolder=samples.appendingPathComponent("目标文件夹");try fm.createDirectory(at:targetFolder,withIntermediateDirectories:false)
try refs.add([targetFolder],to:b)
refs.zones[0].locked=true;try refs.save()
try blocked("locked source cannot cross zones"){try refs.transfer(files[0].path,from:a,to:b)}
try blocked("locked source cannot reorder"){_ = try engine.reorder([files[0].path],in:a,at:0)}
try blocked("locked source cannot enter a folder"){_ = try engine.moveIntoFolder([files[0]],path:targetFolder.path,in:b,sourceZone:a)}
refs.zones[0].locked=false;refs.zones[1].locked=true;try refs.save()
try blocked("locked destination cannot accept insertion"){_ = try engine.collect([files[0]],to:b,at:0)}
try blocked("locked destination folder rejects file"){_ = try engine.moveIntoFolder([files[0]],path:targetFolder.path,in:b)}
refs.zones[1].locked=false;try refs.save()
// Explicitly dropping on a folder moves into its contents and removes loose icons.
try engine.moveIntoFolder([files[1],files[2]],path:targetFolder.path,in:b)
for f in [files[1],files[2]] {let n=targetFolder.appendingPathComponent(f.lastPathComponent);let v=snapshots[f.path]!;try check(!StorageEngine.exists(f.path) && FileIdentity(url:n)==v.0 && Data(contentsOf:n)==v.1,"same-zone folder drop moves and preserves "+f.lastPathComponent)}
try check(refs.zones[1].paths==[files[3].path,targetFolder.path],"folder contents disappear from loose icons; folder remains")
try engine.undo();try check(refs.zones[1].paths==[files[1].path,files[2].path,files[3].path,targetFolder.path],"undo folder drop restores loose icon positions")
try engine.moveIntoFolder([files[0]],path:targetFolder.path,in:b)
try check(refs.zones[0].paths==[files[3].path] && StorageEngine.exists(targetFolder.appendingPathComponent(files[0].lastPathComponent).path),"cross-zone folder drop removes source icon and moves into actual folder")
try engine.undo()
try Data("collision keep".utf8).write(to:targetFolder.appendingPathComponent(files[0].lastPathComponent))
let beforeCollision=refs.zones
try blocked("folder collision preserves entire source group"){_ = try engine.moveIntoFolder([files[0],files[1]],path:targetFolder.path,in:b)}
try check(refs.zones==beforeCollision && files[0].path != targetFolder.path && StorageEngine.exists(files[0].path) && StorageEngine.exists(files[1].path),"failed folder batch changes no references or source files")
try blocked("folder cannot move into itself"){_ = try engine.moveIntoFolder([targetFolder],path:targetFolder.path,in:b)}
// Physical cross-zone insertion and undo restore both order and sort mode.
let incoming=try newFile("physical.txt"),left=try newFile("left.txt"),right=try newFile("right.txt")
try engine.collect([left,right],to:b)
let oldB=refs.zones[1],visible=oldB.orderedPaths
let identity=try FileIdentity(url:incoming)
try engine.collect([incoming],to:b,at:1,displayOrder:visible)
let managed=try engine.folder(b).appendingPathComponent(incoming.lastPathComponent)
try check(refs.zones[1].paths==GridOrder.inserting([managed.path],into:visible,at:1) && FileIdentity(url:managed)==identity,"physical collect commits insertion position with file move")
try engine.undo();try check(refs.zones[1]==oldB && FileIdentity(url:incoming)==identity,"physical insertion undo restores exact previous target order")
// An injected final journal failure must roll back both disk movement and ordering.
var failOnce=true
let failing=try StorageEngine(home:base,references:refs,writer:{data,url in
 let j=try JSONDecoder().decode(StorageJournal.self,from:data)
 if failOnce && j.records.last?.state=="done" {failOnce=false;throw NSError(domain:"injected final save",code:1)}
 try data.write(to:url,options:.atomic)
})
let beforeFailure=refs.zones
try blocked("physical insertion final-save failure rolls back"){_ = try failing.collect([incoming],to:b,at:0)}
try check(refs.zones==beforeFailure && StorageEngine.exists(incoming.path) && !StorageEngine.exists(managed.path),"rollback retains original and target order")
// Reloading persisted order must not reinterpret the index as a file operation.
let reloaded=try ReferenceStore(root:samples,config:refs.config,allowPersonalFiles:true)
try check(reloaded.zones==refs.zones,"grid order survives relaunch")
let oldJournal=base.appendingPathComponent("old-journal.json")
var raw=try JSONSerialization.jsonObject(with:Data(contentsOf:engine.journalURL)) as! [String:Any]
raw["records"]=(raw["records"] as! [[String:Any]]).map{r in var v=r;v.removeValue(forKey:"orderChange");return v}
try JSONSerialization.data(withJSONObject:raw).write(to:oldJournal)
try check(JSONDecoder().decode(StorageJournal.self,from:Data(contentsOf:oldJournal)).records.allSatisfy{$0.orderChange==nil},"pre-grid journal format remains readable")
print("ALL GRID ORDER AND FOLDER DROP TESTS PASSED")
