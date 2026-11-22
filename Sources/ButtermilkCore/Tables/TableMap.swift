import Foundation

/// A rectangle of table cells, in column and row indices. `right` and `bottom` are exclusive.
public struct TableRect: Equatable {
    public var left: Int, top: Int, right: Int, bottom: Int
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

/// A structural problem found while mapping a table. ``Tables/fixTables(_:oldState:)`` repairs them.
public enum TableProblem: Equatable {
    case collision(row: Int, pos: Int, n: Int)
    case missing(row: Int, n: Int)
    case overlongRowspan(pos: Int, n: Int)
    case colwidthMismatch(pos: Int, colwidth: [JSON])
    case zeroSized

    public func toJSON() -> JSON {
        switch self {
        case let .collision(row, pos, n): return ["type": "collision", "row": row.json, "pos": pos.json, "n": n.json]
        case let .missing(row, n): return ["type": "missing", "row": row.json, "n": n.json]
        case let .overlongRowspan(pos, n): return ["type": "overlong_rowspan", "pos": pos.json, "n": n.json]
        case let .colwidthMismatch(pos, colwidth): return ["type": "colwidth mismatch", "pos": pos.json, "colwidth": .array(colwidth)]
        case .zeroSized: return ["type": "zero_sized"]
        }
    }
}

/// The direction to step through a table.
public enum TableAxis { case horizontal, vertical }

/// Describes the structure of a table: for every grid slot, the offset of the cell covering it,
/// relative to the start of the table. Maps are cached per table node.
public final class TableMap {
    public let width: Int
    public let height: Int
    /// For each slot (row by row), the offset of its cell relative to the table start.
    public let map: [Int]
    /// Problems found in the table, or nil when it is well-formed.
    public internal(set) var problems: [TableProblem]?

    init(width: Int, height: Int, map: [Int], problems: [TableProblem]?) {
        self.width = width; self.height = height; self.map = map; self.problems = problems
    }

    /// The rectangle covered by the cell at offset `pos`. The offset must point at a cell.
    public func findCell(_ pos: Int) -> TableRect {
        guard let i = map.firstIndex(of: pos) else { preconditionFailure("No cell with offset \(pos) found") }
        let left = i % width, top = i / width
        var right = left + 1, bottom = top + 1
        var j = 1
        while right < width && map[i + j] == pos { right += 1; j += 1 }
        j = 1
        while bottom < height && map[i + width * j] == pos { bottom += 1; j += 1 }
        return TableRect(left: left, top: top, right: right, bottom: bottom)
    }

    /// The left column of the cell at offset `pos`.
    public func colCount(_ pos: Int) -> Int {
        guard let i = map.firstIndex(of: pos) else { preconditionFailure("No cell with offset \(pos) found") }
        return i % width
    }

    /// The offset of the next cell from the cell at `pos` along `axis`, or nil at the table edge.
    public func nextCell(_ pos: Int, _ axis: TableAxis, _ dir: Int) -> Int? {
        let r = findCell(pos)
        if axis == .horizontal {
            if dir < 0 ? r.left == 0 : r.right == width { return nil }
            return map[r.top * width + (dir < 0 ? r.left - 1 : r.right)]
        }
        if dir < 0 ? r.top == 0 : r.bottom == height { return nil }
        return map[r.left + width * (dir < 0 ? r.top - 1 : r.bottom)]
    }

    /// The smallest rectangle covering the cells at offsets `a` and `b`.
    public func rectBetween(_ a: Int, _ b: Int) -> TableRect {
        let ra = findCell(a), rb = findCell(b)
        return TableRect(left: min(ra.left, rb.left), top: min(ra.top, rb.top),
                         right: max(ra.right, rb.right), bottom: max(ra.bottom, rb.bottom))
    }

    /// The offsets of the cells whose top left corner lies in `rect`.
    public func cellsInRect(_ rect: TableRect) -> [Int] {
        var result: [Int] = [], seen = Set<Int>()
        for row in max(rect.top, 0)..<max(rect.bottom, rect.top, 0) {
            for col in max(rect.left, 0)..<max(rect.right, rect.left, 0) {
                let index = row * width + col
                let pos = map[index]
                if seen.contains(pos) { continue }
                seen.insert(pos)
                if (col == rect.left && col > 0 && map[index - 1] == pos) ||
                    (row == rect.top && row > 0 && map[index - width] == pos) { continue }
                result.append(pos)
            }
        }
        return result
    }

    /// The offset at which a cell at `row`, `col` starts, or would start if inserted there.
    public func positionAt(_ row: Int, _ col: Int, _ table: Node) -> Int {
        var rowStart = 0
        for i in 0... {
            let rowEnd = rowStart + table.child(i).nodeSize
            if i == row {
                var index = col + row * width
                let rowEndIndex = (row + 1) * width
                while index < rowEndIndex && map[index] < rowStart { index += 1 }
                return index == rowEndIndex ? rowEnd - 1 : map[index]
            }
            rowStart = rowEnd
        }
        fatalError("unreachable")
    }

    /// The map for `table`, which must be a node with table role `table`.
    public static func get(_ table: Node) -> TableMap {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache.object(forKey: table) { return cached }
        let map = compute(table)
        cache.setObject(map, forKey: table)
        return map
    }

    private static let cache = NSMapTable<Node, TableMap>.weakToStrongObjects()
    private static let lock = NSLock()

    static func compute(_ table: Node) -> TableMap {
        precondition(table.type.tableRole == "table", "Not a table node: \(table.type.name)")
        let width = findWidth(table), height = table.childCount
        let (size, overflow) = max(width, 0).multipliedReportingOverflow(by: height)
        precondition(!overflow && size <= 50_000_000, "Table too large")
        var map = [Int](repeating: 0, count: size)
        var mapPos = 0
        var problems: [TableProblem]?
        var colWidths: [Int: (w: Double, n: Int)] = [:]
        func add(_ p: TableProblem) { problems = (problems ?? []) + [p] }
        var pos = 0
        for row in 0..<height {
            let rowNode = table.child(row)
            pos += 1
            var i = 0
            while true {
                while mapPos < map.count && map[mapPos] != 0 { mapPos += 1 }
                if i == rowNode.childCount { break }
                let cell = rowNode.child(i)
                let colspan = cell.colspan, rowspan = cell.rowspan, colwidth = cell.attrs["colwidth"]?.arrayValue
                for h in 0..<max(rowspan, 0) {
                    if h + row >= height {
                        add(.overlongRowspan(pos: pos, n: rowspan - h))
                        break
                    }
                    let start = mapPos + h * width
                    for w in 0..<max(colspan, 0) {
                        if start + w < map.count && map[start + w] == 0 { map[start + w] = pos }
                        else { add(.collision(row: row, pos: pos, n: colspan - w)) }
                        if let colW = colwidth?[safe: w]?.doubleValue, colW != 0, !colW.isNaN, width > 0 {
                            let col = (start + w) % width
                            if let prev = colWidths[col] {
                                if prev.w != colW && prev.n == 1 { colWidths[col] = (colW, 1) }
                                else if prev.w == colW { colWidths[col]!.n += 1 }
                            } else {
                                colWidths[col] = (colW, 1)
                            }
                        }
                    }
                }
                mapPos += colspan
                pos += cell.nodeSize
                i += 1
            }
            let expectedPos = (row + 1) * width
            var missing = 0
            while mapPos < expectedPos {
                if map[mapPos] == 0 { missing += 1 }
                mapPos += 1
            }
            if missing > 0 { add(.missing(row: row, n: missing)) }
            pos += 1
        }
        if width == 0 || height == 0 { add(.zeroSized) }
        let tableMap = TableMap(width: width, height: height, map: map, problems: problems)
        if colWidths.values.contains(where: { $0.n < height }) {
            findBadColWidths(tableMap, colWidths.mapValues { $0.w }, table)
        }
        return tableMap
    }

    private static func findWidth(_ table: Node) -> Int {
        var width = -1, hasRowSpan = false
        for row in 0..<table.childCount {
            let rowNode = table.child(row)
            var rowWidth = 0
            if hasRowSpan {
                for j in 0..<row {
                    let prev = table.child(j)
                    for i in 0..<prev.childCount where j + prev.child(i).rowspan > row { rowWidth += prev.child(i).colspan }
                }
            }
            for i in 0..<rowNode.childCount {
                let cell = rowNode.child(i)
                rowWidth += cell.colspan
                if cell.rowspan > 1 { hasRowSpan = true }
            }
            width = width == -1 ? rowWidth : max(width, rowWidth)
        }
        return width
    }

    private static func findBadColWidths(_ map: TableMap, _ colWidths: [Int: Double], _ table: Node) {
        if map.problems == nil { map.problems = [] }
        var seen = Set<Int>()
        for i in 0..<map.map.count {
            let pos = map.map[i]
            if seen.contains(pos) { continue }
            seen.insert(pos)
            guard let node = table.nodeAt(pos) else { preconditionFailure("No cell with offset \(pos) found") }
            var updated: [JSON]?
            let existing = node.attrs["colwidth"]?.arrayValue
            // A missing slot maps to offset 0, the first row, which has no colspan.
            for j in 0..<(node.attrs["colspan"] == nil ? 0 : node.colspan) {
                guard let colWidth = colWidths[(i + j) % map.width] else { continue }
                if existing == nil || existing?[safe: j]?.doubleValue != colWidth {
                    if updated == nil { updated = existing ?? Array(repeating: .number(0), count: node.colspan) }
                    while updated!.count <= j { updated!.append(.null) }
                    updated![j] = .number(colWidth)
                }
            }
            if let updated { map.problems!.insert(.colwidthMismatch(pos: pos, colwidth: updated), at: 0) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}

public extension NodeType {
    /// The table role from `spec.extra["tableRole"]`: `table`, `row`, `cell` or `header_cell`.
    var tableRole: String? { spec.extra["tableRole"] as? String }
}

/// Spans outside this range are clamped, so a hostile document cannot make table maps huge.
let maxCellSpan = 1000

func clampSpan(_ value: JSON?) -> Int { min(max(value?.intValue ?? 1, 1), maxCellSpan) }

extension Node {
    var colspan: Int { clampSpan(attrs["colspan"]) }
    var rowspan: Int { clampSpan(attrs["rowspan"]) }
    var isCellNode: Bool { type.tableRole == "cell" || type.tableRole == "header_cell" }
}
