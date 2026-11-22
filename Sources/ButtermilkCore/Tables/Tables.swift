/// Table support: schema nodes, helpers, the table fixer and the table editing plugin.
/// Port of prosemirror-tables. Column resizing and mouse cell selection are view concerns.
public enum Tables {
    // MARK: Schema

    /// Extra cell attribute, added to both cell types by ``nodes(cellContent:cellAttributes:tableGroup:)``.
    public struct CellAttribute {
        public var `default`: JSON?
        public var validate: ((JSON) throws -> Void)?
        public init(default: JSON?, validate: ((JSON) throws -> Void)? = nil) { self.default = `default`; self.validate = validate }
    }

    /// Node specs for `table`, `table_row`, `table_cell` and `table_header`.
    public static func nodes(cellContent: String, cellAttributes: [String: CellAttribute] = [:],
                             tableGroup: String? = nil) -> [(String, NodeSpec)] {
        let span: (JSON) throws -> Void = { value in
            guard let n = value.intValue, n >= 1, n <= maxCellSpan else {
                throw ProseError.range("Cell spans must be whole numbers from 1 to \(maxCellSpan)")
            }
        }
        var attrs: [String: AttributeSpec] = [
            "colspan": AttributeSpec(default: 1, validate: span),
            "rowspan": AttributeSpec(default: 1, validate: span),
            "colwidth": AttributeSpec(default: .null, validate: { value in
                if value == .null { return }
                guard let items = value.arrayValue else { throw ProseError.range("colwidth must be null or an array") }
                for item in items where item.doubleValue == nil {
                    throw ProseError.range("colwidth must be null or an array of numbers")
                }
            }),
        ]
        for (name, a) in cellAttributes { attrs[name] = AttributeSpec(default: a.default, validate: a.validate) }
        var table = NodeSpec(content: "table_row+", group: tableGroup)
        table.isolating = true
        table.extra["tableRole"] = "table"
        var row = NodeSpec(content: "(table_cell | table_header)*")
        row.extra["tableRole"] = "row"
        var cell = NodeSpec(content: cellContent)
        cell.attrs = attrs
        cell.isolating = true
        cell.extra["tableRole"] = "cell"
        var header = cell
        header.extra["tableRole"] = "header_cell"
        return [("table", table), ("table_row", row), ("table_cell", cell), ("table_header", header)]
    }

    /// The schema's table node types, keyed by table role (`table`, `row`, `cell`, `header_cell`).
    public static func nodeTypes(_ schema: Schema) -> [String: NodeType] {
        if let cached = schema.cached["tableNodeTypes"] as? [String: NodeType] { return cached }
        var result: [String: NodeType] = [:]
        for (name, _) in schema.nodeSpecs {
            if let type = schema.nodes[name], let role = type.tableRole { result[role] = type }
        }
        schema.cached["tableNodeTypes"] = result
        return result
    }

    // MARK: Helpers

    /// The position in front of the cell that contains `pos`, if any.
    public static func cellAround(_ pos: ResolvedPos) -> ResolvedPos? {
        var d = pos.depth - 1
        while d > 0 {
            if pos.node(d).type.tableRole == "row" {
                // Oversized tables have no map, so table editing leaves them alone.
                guard d > 0, isUsable(pos.node(d - 1)) else { return nil }
                return pos.node(0).resolve(pos.before(d + 1))
            }
            d -= 1
        }
        return nil
    }

    static func cellWrapping(_ pos: ResolvedPos) -> Node? {
        var d = pos.depth
        while d > 0 {
            if pos.node(d).isCellNode { return d >= 2 && isUsable(pos.node(d - 2)) ? pos.node(d) : nil }
            d -= 1
        }
        return nil
    }

    /// Whether `table` is small enough to have a table map.
    static func isUsable(_ table: Node) -> Bool {
        TableMap.get(table).problems?.contains(.tooLarge) != true
    }

    /// Whether the selection head is inside a table.
    public static func isInTable(_ state: EditorState) -> Bool {
        let head = state.selection.resolvedHead
        var d = head.depth
        while d > 0 {
            if head.node(d).type.tableRole == "row" { return isUsable(head.node(d - 1)) }
            d -= 1
        }
        return false
    }

    /// The cell the selection is in, or the cell nearest to it.
    public static func selectionCell(_ state: EditorState) -> ResolvedPos? {
        guard let cell = selectionCellUnchecked(state), cell.depth > 0, isUsable(cell.node(-1)) else { return nil }
        return cell
    }

    private static func selectionCellUnchecked(_ state: EditorState) -> ResolvedPos? {
        let sel = state.selection
        if let cells = sel as? CellSelection {
            return cells.anchorCell.pos > cells.headCell.pos ? cells.anchorCell : cells.headCell
        }
        if let node = (sel as? NodeSelection)?.node, node.type.tableRole == "cell" { return sel.resolvedAnchor }
        return cellAround(sel.resolvedHead) ?? cellNear(sel.resolvedHead)
    }

    /// The position in front of the first cell directly after or before `pos`.
    public static func cellNear(_ pos: ResolvedPos) -> ResolvedPos? {
        var after = pos.nodeAfter, p = pos.pos
        while let node = after {
            if node.isCellNode { return pos.doc.resolve(p) }
            after = node.firstChild; p += 1
        }
        var before = pos.nodeBefore
        p = pos.pos
        while let node = before {
            if node.isCellNode { return pos.doc.resolve(p - node.nodeSize) }
            before = node.lastChild; p -= 1
        }
        return nil
    }

    /// Whether `pos` points in front of a cell that the table map knows about. Use it to check
    /// untrusted positions before building a ``CellSelection``.
    public static func isCellPosition(_ pos: ResolvedPos) -> Bool {
        guard pointsAtCell(pos), pos.depth >= 2, pos.node(-1).type.tableRole == "table" else { return false }
        return TableMap.get(pos.node(-1)).map.contains(pos.pos - pos.start(-1))
    }

    /// Whether `pos` points in front of a cell.
    public static func pointsAtCell(_ pos: ResolvedPos) -> Bool {
        pos.parent.type.tableRole == "row" && pos.nodeAfter != nil
    }

    /// Move a position in front of a cell to the position after it.
    public static func moveCellForward(_ pos: ResolvedPos) -> ResolvedPos {
        pos.node(0).resolve(pos.pos + pos.nodeAfter!.nodeSize)
    }

    /// Whether two cell positions are in the same table.
    public static func inSameTable(_ a: ResolvedPos, _ b: ResolvedPos) -> Bool {
        a.depth == b.depth && a.depth > 0 && a.pos >= b.start(-1) && a.pos <= b.end(-1)
    }

    /// The rectangle of the cell at `pos`.
    public static func findCell(_ pos: ResolvedPos) -> TableRect {
        TableMap.get(pos.node(-1)).findCell(pos.pos - pos.start(-1))
    }

    /// The left column of the cell at `pos`.
    public static func colCount(_ pos: ResolvedPos) -> Int {
        TableMap.get(pos.node(-1)).colCount(pos.pos - pos.start(-1))
    }

    /// The position of the next cell from the cell at `pos`, or nil at the table edge.
    public static func nextCell(_ pos: ResolvedPos, _ axis: TableAxis, _ dir: Int) -> ResolvedPos? {
        let table = pos.node(-1), start = pos.start(-1)
        guard let moved = TableMap.get(table).nextCell(pos.pos - start, axis, dir) else { return nil }
        return pos.node(0).resolve(start + moved)
    }

    /// Cell attributes with `n` columns removed at column `pos` within the cell.
    public static func removeColSpan(_ attrs: Attrs, _ pos: Int, _ n: Int = 1) -> Attrs {
        var result = attrs
        result["colspan"] = (attrs.colspan - n).json
        if var widths = attrs["colwidth"]?.arrayValue {
            widths.removeSubrange(min(pos, widths.count)..<min(pos + n, widths.count))
            result["colwidth"] = widths.contains { ($0.doubleValue ?? 0) > 0 } ? .array(widths) : .null
        }
        return result
    }

    /// Cell attributes with `n` columns added at column `pos` within the cell.
    public static func addColSpan(_ attrs: Attrs, _ pos: Int, _ n: Int = 1) -> Attrs {
        var result = attrs
        result["colspan"] = (attrs.colspan + n).json
        if var widths = attrs["colwidth"]?.arrayValue {
            for _ in 0..<max(n, 0) { widths.insert(.number(0), at: min(max(pos, 0), widths.count)) }
            result["colwidth"] = .array(widths)
        }
        return result
    }

    /// Whether every cell in column `col` is a header cell.
    public static func columnIsHeader(_ map: TableMap, _ table: Node, _ col: Int) -> Bool {
        let header = nodeTypes(table.type.schema)["header_cell"]
        for row in 0..<map.height where table.nodeAt(map.map[col + row * map.width])?.type !== header { return false }
        return true
    }

    /// Whether every cell in row `row` is a header cell.
    public static func rowIsHeader(_ map: TableMap, _ table: Node, _ row: Int) -> Bool {
        let header = nodeTypes(table.type.schema)["header_cell"]
        for col in 0..<max(map.width, 0) where table.nodeAt(map.map[col + row * map.width])?.type !== header { return false }
        return true
    }

    /// A table found around a position.
    public struct FoundNode {
        public let node: Node
        public let pos: Int
        public let start: Int
        public let depth: Int
    }

    /// The closest table around `pos`.
    public static func findTable(_ pos: ResolvedPos) -> FoundNode? {
        var depth = pos.depth
        while depth >= 0 {
            let node = pos.node(depth)
            if node.type.tableRole == "table" {
                return FoundNode(node: node, pos: depth == 0 ? 0 : pos.before(depth), start: pos.start(depth), depth: depth)
            }
            depth -= 1
        }
        return nil
    }

    /// The cell position around or next to document position `pos`.
    public static func findCellPos(_ doc: Node, _ pos: Int) -> ResolvedPos? {
        let p = doc.resolve(pos)
        return cellAround(p) ?? cellNear(p)
    }

    /// Anchor and head cells in one table, using the hit points or else the selection's ends.
    public static func findCellRange(_ selection: Selection, anchorHit: Int? = nil, headHit: Int? = nil)
        -> (anchor: ResolvedPos, head: ResolvedPos)? {
        if anchorHit == nil && headHit == nil, let cells = selection as? CellSelection { return (cells.anchorCell, cells.headCell) }
        let anchor = anchorHit ?? headHit ?? selection.anchor
        let head = headHit ?? anchorHit ?? selection.head
        let doc = selection.resolvedHead.doc
        if let a = findCellPos(doc, anchor), let h = findCellPos(doc, head), inSameTable(a, h) { return (a, h) }
        return nil
    }

    // MARK: Fixing tables

    /// Meta key set on transactions created by ``fixTables(_:oldState:)``.
    public static let fixTablesKey = PluginKey<Never>("fix-tables")

    /// Call `f` for every node in `cur` that changed compared to `old`.
    public static func changedDescendants(_ old: Node, _ cur: Node, _ offset: Int, _ f: (Node, Int) -> Void) {
        var offset = offset
        let oldSize = old.childCount, curSize = cur.childCount
        var j = 0
        outer: for i in 0..<curSize {
            let child = cur.child(i)
            var scan = j
            while scan < min(oldSize, i + 3) {
                if old.child(scan) === child {
                    j = scan + 1
                    offset += child.nodeSize
                    continue outer
                }
                scan += 1
            }
            f(child, offset)
            if j < oldSize && old.child(j).sameMarkup(child) {
                changedDescendants(old.child(j), child, offset + 1, f)
            } else {
                child.nodesBetween(0, child.content.size, startPos: offset + 1) { node, pos, _, _ in f(node, pos); return true }
            }
            offset += child.nodeSize
        }
    }

    /// A transaction that repairs every malformed table in `state`, or nil when all are fine.
    /// With `oldState`, only the parts of the document that changed since then are checked.
    public static func fixTables(_ state: EditorState, oldState: EditorState? = nil) -> Transaction? {
        var tr: Transaction?
        let check: (Node, Int) -> Void = { node, pos in
            if node.type.tableRole == "table" { tr = fixTable(state, node, pos, tr) }
        }
        if let oldState {
            if oldState.doc !== state.doc { changedDescendants(oldState.doc, state.doc, 0, check) }
        } else {
            state.doc.descendants { node, pos, _, _ in check(node, pos); return true }
        }
        return tr
    }

    static func fixTable(_ state: EditorState, _ table: Node, _ tablePos: Int, _ tr: Transaction?) -> Transaction? {
        let map = TableMap.get(table)
        guard let problems = map.problems else { return tr }
        let tr = tr ?? state.tr
        var mustAdd = [Int](repeating: 0, count: map.height)
        for prob in problems {
            switch prob {
            case let .collision(row, pos, n):
                guard let cell = table.nodeAt(pos) else { continue }
                for j in 0..<cell.rowspan where row + j < mustAdd.count { mustAdd[row + j] += n }
                _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), attrs: removeColSpan(cell.attrs, cell.colspan - n, n))
            case let .missing(row, n):
                mustAdd[row] += n
            case let .overlongRowspan(pos, n):
                guard let cell = table.nodeAt(pos) else { continue }
                var attrs = cell.attrs
                attrs["rowspan"] = (cell.rowspan - n).json
                _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), attrs: attrs)
            case let .colwidthMismatch(pos, colwidth):
                guard let cell = table.nodeAt(pos) else { continue }
                var attrs = cell.attrs
                attrs["colwidth"] = .array(colwidth)
                _ = try? tr.setNodeMarkup(tr.mapping.map(tablePos + 1 + pos), attrs: attrs)
            case .zeroSized:
                let pos = tr.mapping.map(tablePos)
                _ = try? tr.delete(pos, pos + table.nodeSize)
            case .tooLarge:
                // Too large to repair safely; leave it as is.
                break
            }
        }
        let first = mustAdd.firstIndex { $0 != 0 }, last = mustAdd.lastIndex { $0 != 0 }
        var pos = tablePos + 1
        for i in 0..<map.height {
            let row = table.child(i)
            let end = pos + row.nodeSize
            let add = mustAdd[i]
            if add > 0 {
                let role = row.firstChild?.type.tableRole ?? "cell"
                var nodes: [Node] = []
                for _ in 0..<add {
                    if let node = nodeTypes(state.schema)[role]?.createAndFill() { nodes.append(node) }
                }
                let side = (i == 0 || first == i - 1) && last == i ? pos + 1 : end - 1
                _ = try? tr.insert(tr.mapping.map(side), nodes)
            }
            pos = end
        }
        return tr.setMeta(fixTablesKey, ["fixTables": true])
    }

    // MARK: Selection normalization

    static func isCellBoundarySelection(_ sel: Selection) -> Bool {
        let from = sel.resolvedFrom, to = sel.resolvedTo
        if from.pos == to.pos || from.pos < to.pos - 6 { return false }
        var afterFrom = from.pos, beforeTo = to.pos
        var depth = from.depth
        while depth >= 0 {
            if from.after(depth + 1) < from.end(depth) { break }
            depth -= 1; afterFrom += 1
        }
        var d = to.depth
        while d >= 0 {
            if to.before(d + 1) > to.start(d) { break }
            d -= 1; beforeTo -= 1
        }
        guard afterFrom == beforeTo, let role = from.node(depth).type.tableRole else { return false }
        return role.contains("row") || role.contains("table")
    }

    static func isTextSelectionAcrossCells(_ sel: Selection) -> Bool {
        func cellNode(_ pos: ResolvedPos) -> Node? {
            var i = pos.depth
            while i > 0 {
                if pos.node(i).isCellNode { return pos.node(i) }
                i -= 1
            }
            return nil
        }
        return cellNode(sel.resolvedFrom) !== cellNode(sel.resolvedTo) && sel.resolvedTo.parentOffset == 0
    }

    /// Turn node selections of cells, rows or tables into cell selections, and collapse text
    /// selections that only cross cell boundaries.
    public static func normalizeSelection(_ state: EditorState, _ tr: Transaction?,
                                          allowTableNodeSelection: Bool = false) -> Transaction? {
        let sel = tr?.selection ?? state.selection
        let doc = tr?.doc ?? state.doc
        var normalize: Selection?
        if let nodeSel = sel as? NodeSelection, let role = nodeSel.node.type.tableRole {
            let rFrom = doc.resolve(sel.from)
            let table = role == "table" ? nodeSel.node : role == "row" ? rFrom.parent : rFrom.depth > 0 ? rFrom.node(-1) : rFrom.parent
            if !isUsable(table) {
                // No map for oversized tables: keep the node selection.
            } else if role == "cell" || role == "header_cell" {
                normalize = CellSelection(doc.resolve(sel.from))
            } else if role == "row" {
                let cell = doc.resolve(sel.from + 1)
                normalize = CellSelection.rowSelection(cell, cell)
            } else if !allowTableNodeSelection, role == "table" {
                let map = TableMap.get(nodeSel.node)
                let start = sel.from + 1
                let lastCell = start + map.map[map.width * map.height - 1]
                normalize = CellSelection(doc.resolve(start + 1), doc.resolve(lastCell))
            }
        } else if sel is TextSelection && isCellBoundarySelection(sel) {
            normalize = TextSelection.create(doc, sel.from)
        } else if sel is TextSelection && isTextSelectionAcrossCells(sel) {
            normalize = TextSelection.create(doc, sel.resolvedFrom.start(), sel.resolvedFrom.end())
        }
        guard let normalize else { return tr }
        let result = tr ?? state.tr
        result.setSelection(normalize)
        return result
    }
}
