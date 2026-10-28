import Foundation
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); print("PASS: " + message)
}
require(GridDropLayout.columnCount(width: 430) == 4 && GridDropLayout.columnCount(width: 268) == 2 && GridDropLayout.columnCount(width: 269) == 3, "column counts respect exact square-cell boundaries")
require(GridDropLayout.columnCount(width: 100) == 1, "narrow windows still retain one column")
require(GridDropLayout.columnCount(width: 240) == 2 && GridDropLayout.columnCount(width: 322) == 3, "existing narrow partitions now fit more columns without resizing")
let screen = ZoneFrame(x: -1920, y: 38, width: 1920, height: 1010)
var zone = Zone(title: "fixture", x: -400, y: 500, width: 320, height: 280)
let original = zone.frameValue
for count in [0, 1, 2, 4, 12, 24, 48, 96, 300] {
    let expanded = zone.contentFrame(on: screen, itemCount: count)
    require(expanded.x >= screen.x && expanded.y >= screen.y && expanded.x + expanded.width <= screen.x + screen.width && expanded.y + expanded.height <= screen.y + screen.height, "expanded grid remains inside the display for \(count) items")
    if count <= 2 { require(expanded == original, "already fitting files do not resize their partition") }
    if count > 2 && expanded != screen {
        let columns = GridDropLayout.columnCount(width: expanded.width)
        let rows = Int(ceil(Double(count) / Double(columns)))
        require(20 + Double(columns) * 81 + Double(columns - 1) * 3 <= expanded.width + 0.01 && 102 + Double(rows) * 81 + Double(rows - 1) * 3 <= expanded.height + 0.01, "expanded partition fits the measured grid for \(count) items")
    }
    zone.toggleMaximum(on: screen, itemCount: count)
    if zone.isMaximized { zone.toggleMaximum(on: screen) }
    require(zone.frameValue == original && !zone.isMaximized, "restore retains exact user geometry for \(count) items")
}
print("ALL GRID GEOMETRY CHECKS PASSED")
