import Foundation
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("pans-desktop-datahome-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false)
defer {try? fm.removeItem(at:root)}
func sameLocation(_ a:URL,_ b:URL)->Bool {a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path}
func check(_ value:Bool,_ message:String){guard value else{fatalError(message)};print("PASS: "+message)}
let bundle=root.appendingPathComponent("Applications/Pan's Desktop.app")
check(try AppDataHome.resolve(bundleURL:bundle,bookmarkURL:nil)==bundle.deletingLastPathComponent(),"portable app keeps adjacent data layout")
let data=root.appendingPathComponent("OriginalData"),config=data.appendingPathComponent("Configuration/zones.json")
try fm.createDirectory(at:config.deletingLastPathComponent(),withIntermediateDirectories:true)
let contents=Data("[{\"title\":\"Synthetic only\"}]".utf8);try contents.write(to:config)
let bookmark=root.appendingPathComponent("ExistingDataHome.bookmark")
try data.bookmarkData(options:.withoutImplicitSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil).write(to:bookmark)
check(try sameLocation(AppDataHome.resolve(bundleURL:bundle,bookmarkURL:bookmark),data),"installed app resolves existing data without moving it")
let renamed=root.appendingPathComponent("RenamedFixtureData");try fm.moveItem(at:data,to:renamed)
check(try sameLocation(AppDataHome.resolve(bundleURL:bundle,bookmarkURL:bookmark),renamed),"bookmark follows renamed test data folder")
let current=renamed.appendingPathComponent("Configuration/zones.json"),hidden=current.appendingPathExtension("unavailable")
try fm.moveItem(at:current,to:hidden)
do {_ = try AppDataHome.resolve(bundleURL:bundle,bookmarkURL:bookmark);fatalError("silently accepted missing configuration")}catch AppDataHomeError.unavailable {print("PASS: missing existing config fails closed instead of making new partitions")}
check(!fm.fileExists(atPath:bundle.deletingLastPathComponent().appendingPathComponent("Configuration").path),"failure creates no replacement application-directory config")
try fm.moveItem(at:hidden,to:current)
try Data("invalid bookmark".utf8).write(to:bookmark)
do {_ = try AppDataHome.resolve(bundleURL:bundle,bookmarkURL:bookmark);fatalError("silently accepted bad bookmark")}catch AppDataHomeError.unavailable {print("PASS: corrupt bookmark fails closed")}
check(try Data(contentsOf:current)==contents,"existing fixture configuration bytes remain unchanged")
