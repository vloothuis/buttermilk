/// A selection of a rectangle of table cells. Port of prosemirror-tables' `CellSelection`.
///
/// `anchorCell` and `headCell` point directly in front of a cell (their parent is a row).
public final class CellSelection: Selection {
    public override class var jsonID: String { "cell" }

    public let anchorCell: ResolvedPos
    public let headCell: ResolvedPos

    /// Both positions must point in front of a cell in the same table.
    public init(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) {
        let headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        var cells = map.cellsInRect(rect).filter { $0 != headCell.pos - tableStart }
        cells.insert(headCell.pos - tableStart, at: 0)
        let ranges = cells.map { pos -> SelectionRange in
            guard let cell = table.nodeAt(pos) else { preconditionFailure("No cell with offset \(pos) found") }
            let from = tableStart + pos + 1
            return SelectionRange(doc.resolve(from), doc.resolve(from + cell.content.size))
        }
        self.anchorCell = anchorCell
        self.headCell = headCell
        super.init(ranges[0].from, ranges[0].to, ranges: ranges)
    }

    /// A cell selection from document positions. Throws when they do not point at cells in one table.
    public static func create(_ doc: Node, _ anchorCell: Int, _ headCell: Int? = nil) throws -> CellSelection {
        let a = doc.resolve(try checkedPosition(doc, .number(Double(anchorCell))))
        let h = doc.resolve(try checkedPosition(doc, .number(Double(headCell ?? anchorCell))))
        guard Tables.isCellPosition(a), Tables.isCellPosition(h), Tables.inSameTable(a, h) else {
            throw ProseError.range("Cell selection positions must point at cells in the same table")
        }
        return CellSelection(a, h)
    }

    public override var visible: Bool { false }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let a = doc.resolve(mapping.map(anchorCell.pos)), h = doc.resolve(mapping.map(headCell.pos))
        if Tables.pointsAtCell(a) && Tables.pointsAtCell(h) && Tables.inSameTable(a, h) &&
            Tables.isCellPosition(a) && Tables.isCellPosition(h) {
            let tableChanged = anchorCell.node(-1) !== a.node(-1)
            if tableChanged && isRowSelection { return CellSelection.rowSelection(a, h) }
            if tableChanged && isColSelection { return CellSelection.colSelection(a, h) }
            return CellSelection(a, h)
        }
        return TextSelection.between(a, h)
    }

    /// The selected cells as a slice of rows (or the whole table when every cell is selected).
    /// Cells that stick out of the selection are clipped.
    public override func content() -> Slice {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let rect = map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)
        var seen = Set<Int>()
        var rows: [Node] = []
        for row in rect.top..<rect.bottom {
            var rowContent: [Node] = []
            var index = row * map.width + rect.left
            for _ in rect.left..<rect.right {
                defer { index += 1 }
                let pos = map.map[index]
                if seen.contains(pos) { continue }
                seen.insert(pos)
                let cellRect = map.findCell(pos)
                guard var cell = table.nodeAt(pos) else { preconditionFailure("No cell with offset \(pos) found") }
                let extraLeft = rect.left - cellRect.left, extraRight = cellRect.right - rect.right
                if extraLeft > 0 || extraRight > 0 {
                    var attrs = cell.attrs
                    if extraLeft > 0 { attrs = Tables.removeColSpan(attrs, 0, extraLeft) }
                    if extraRight > 0 { attrs = Tables.removeColSpan(attrs, attrs.colspan - extraRight, extraRight) }
                    if cellRect.left < rect.left {
                        guard let filled = cell.type.createAndFill(attrs) else {
                            preconditionFailure("Could not create cell with attrs \(attrs)")
                        }
                        cell = filled
                    } else {
                        cell = makeNode(cell.type, attrs, cell.content)
                    }
                }
                if cellRect.top < rect.top || cellRect.bottom > rect.bottom {
                    var attrs = cell.attrs
                    attrs["rowspan"] = (min(cellRect.bottom, rect.bottom) - max(cellRect.top, rect.top)).json
                    cell = cellRect.top < rect.top ? (cell.type.createAndFill(attrs) ?? cell) : makeNode(cell.type, attrs, cell.content)
                }
                rowContent.append(cell)
            }
            rows.append(table.child(row).copy(Fragment.from(rowContent)))
        }
        let fragment = isColSelection && isRowSelection ? Fragment(table) : Fragment.from(rows)
        return Slice(fragment, openStart: 1, openEnd: 1)
    }

    /// Replace every selected cell's content. Only the first cell receives `content`; nil clears them all.
    public override func replace(_ tr: Transaction, _ content: Slice? = nil) throws {
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            try tr.replace(mapping.map(range.from.pos), mapping.map(range.to.pos), i > 0 ? .empty : content ?? .empty)
        }
        if let sel = Selection.findFrom(tr.doc.resolve(tr.mapping.slice(mapFrom).map(to)), -1) { tr.setSelection(sel) }
    }

    public override func replaceWith(_ tr: Transaction, _ node: Node) throws {
        try replace(tr, Slice(Fragment(node), openStart: 0, openEnd: 0))
    }

    /// Call `f` with every selected cell and its document position.
    public func forEachCell(_ f: (Node, Int) -> Void) {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        for pos in map.cellsInRect(map.rectBetween(anchorCell.pos - tableStart, headCell.pos - tableStart)) {
            f(table.nodeAt(pos)!, tableStart + pos)
        }
    }

    /// Whether the selection spans whole columns (top to bottom).
    public var isColSelection: Bool {
        let anchorTop = anchorCell.index(-1), headTop = headCell.index(-1)
        if min(anchorTop, headTop) > 0 { return false }
        let anchorBottom = anchorTop + (anchorCell.nodeAfter?.rowspan ?? 1)
        let headBottom = headTop + (headCell.nodeAfter?.rowspan ?? 1)
        return max(anchorBottom, headBottom) == headCell.node(-1).childCount
    }

    /// Whether the selection spans whole rows (left to right).
    public var isRowSelection: Bool {
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorLeft = map.colCount(anchorCell.pos - tableStart), headLeft = map.colCount(headCell.pos - tableStart)
        if min(anchorLeft, headLeft) > 0 { return false }
        let anchorRight = anchorLeft + (anchorCell.nodeAfter?.colspan ?? 1)
        let headRight = headLeft + (headCell.nodeAfter?.colspan ?? 1)
        return max(anchorRight, headRight) == map.width
    }

    /// A selection of the full columns spanned by the two cells.
    public static func colSelection(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) -> CellSelection {
        var anchorCell = anchorCell, headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = map.findCell(anchorCell.pos - tableStart), headRect = map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.top <= headRect.top {
            if anchorRect.top > 0 { anchorCell = doc.resolve(tableStart + map.map[anchorRect.left]) }
            if headRect.bottom < map.height {
                headCell = doc.resolve(tableStart + map.map[map.width * (map.height - 1) + headRect.right - 1])
            }
        } else {
            if headRect.top > 0 { headCell = doc.resolve(tableStart + map.map[headRect.left]) }
            if anchorRect.bottom < map.height {
                anchorCell = doc.resolve(tableStart + map.map[map.width * (map.height - 1) + anchorRect.right - 1])
            }
        }
        return CellSelection(anchorCell, headCell)
    }

    /// A selection of the full rows spanned by the two cells.
    public static func rowSelection(_ anchorCell: ResolvedPos, _ headCell: ResolvedPos? = nil) -> CellSelection {
        var anchorCell = anchorCell, headCell = headCell ?? anchorCell
        let table = anchorCell.node(-1)
        let map = TableMap.get(table)
        let tableStart = anchorCell.start(-1)
        let anchorRect = map.findCell(anchorCell.pos - tableStart), headRect = map.findCell(headCell.pos - tableStart)
        let doc = anchorCell.node(0)
        if anchorRect.left <= headRect.left {
            if anchorRect.left > 0 { anchorCell = doc.resolve(tableStart + map.map[anchorRect.top * map.width]) }
            if headRect.right < map.width { headCell = doc.resolve(tableStart + map.map[map.width * (headRect.top + 1) - 1]) }
        } else {
            if headRect.left > 0 { headCell = doc.resolve(tableStart + map.map[headRect.top * map.width]) }
            if anchorRect.right < map.width { anchorCell = doc.resolve(tableStart + map.map[map.width * (anchorRect.top + 1) - 1]) }
        }
        return CellSelection(anchorCell, headCell)
    }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? CellSelection else { return false }
        return o.anchorCell.pos == anchorCell.pos && o.headCell.pos == headCell.pos
    }

    public override func toJSON() -> JSON { ["type": "cell", "anchor": anchorCell.pos.json, "head": headCell.pos.json] }

    public override func getBookmark() -> SelectionBookmark { CellBookmark(anchor: anchorCell.pos, head: headCell.pos) }

    /// Register the `cell` JSON type with ``Selection/fromJSON(_:_:)``. Safe to call more than once.
    public static func registerJSON() {
        if !registered {
            registered = true
            Selection.register("cell") { doc, json in
                try CellSelection.create(doc, try checkedPosition(doc, json["anchor"]), try checkedPosition(doc, json["head"]))
            }
        }
    }
    private static var registered = false
}

public struct CellBookmark: SelectionBookmark {
    public let anchor: Int
    public let head: Int
    public func map(_ mapping: Mappable) -> SelectionBookmark { CellBookmark(anchor: mapping.map(anchor), head: mapping.map(head)) }
    public func resolve(_ doc: Node) -> Selection {
        let a = doc.resolve(anchor), h = doc.resolve(head)
        if a.parent.type.tableRole == "row" && h.parent.type.tableRole == "row" &&
            a.index() < a.parent.childCount && h.index() < h.parent.childCount && Tables.inSameTable(a, h) &&
            Tables.isCellPosition(a) && Tables.isCellPosition(h) {
            return CellSelection(a, h)
        }
        return Selection.near(h, bias: 1)
    }
}

func makeNode(_ type: NodeType, _ attrs: Attrs, _ content: Fragment) -> Node {
    (try? type.create(attrs, content)) ?? Node(type: type, attrs: attrs, content: content)
}

extension Attrs {
    var colspan: Int { clampSpan(self["colspan"]) }
    var rowspan: Int { clampSpan(self["rowspan"]) }
}
