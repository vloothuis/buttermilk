/// A rectangular block of cells taken from a pasted slice.
public struct PastedCells {
    public var width: Int
    public var height: Int
    public var rows: [Fragment]
}

extension Tables {
    // MARK: Copy and paste

    /// The rectangle of cells in `slice`, or nil when its outer nodes are not cells or rows.
    public static func pastedCells(_ slice: Slice) -> PastedCells? {
        if slice.size == 0 { return nil }
        var content = slice.content, openStart = slice.openStart, openEnd = slice.openEnd
        while content.childCount == 1 && ((openStart > 0 && openEnd > 0) || content.child(0).type.tableRole == "table") {
            openStart -= 1; openEnd -= 1
            content = content.child(0).content
        }
        guard let first = content.firstChild else { return nil }
        let role = first.type.tableRole, schema = first.type.schema
        var rows: [Fragment] = []
        if role == "row" {
            for i in 0..<content.childCount {
                var cells = content.child(i).content
                let left = i > 0 ? 0 : max(0, openStart - 1)
                let right = i < content.childCount - 1 ? 0 : max(0, openEnd - 1)
                if left > 0 || right > 0 {
                    guard let fitted = fitSlice(nodeTypes(schema)["row"]!, Slice(cells, openStart: left, openEnd: right)) else { return nil }
                    cells = fitted.content
                }
                rows.append(cells)
            }
        } else if role == "cell" || role == "header_cell" {
            if openStart > 0 || openEnd > 0 {
                guard let fitted = fitSlice(nodeTypes(schema)["row"]!, Slice(content, openStart: openStart, openEnd: openEnd)) else { return nil }
                rows.append(fitted.content)
            } else {
                rows.append(content)
            }
        } else {
            return nil
        }
        return ensureRectangular(schema, rows)
    }

    static func ensureRectangular(_ schema: Schema, _ rows: [Fragment]) -> PastedCells {
        var rows = rows
        var widths: [Int] = []
        for i in 0..<rows.count {
            let row = rows[i]
            var j = row.childCount - 1
            while j >= 0 {
                let cell = row.child(j)
                for r in i..<(i + max(cell.rowspan, 0)) {
                    while widths.count <= r { widths.append(0) }
                    widths[r] += cell.colspan
                }
                j -= 1
            }
        }
        let width = widths.max() ?? 0
        for r in 0..<widths.count {
            if r >= rows.count { rows.append(.empty) }
            if widths[r] < width, let empty = nodeTypes(schema)["cell"]?.createAndFill() {
                rows[r] = rows[r].append(Fragment.from(Array(repeating: empty, count: width - widths[r])))
            }
        }
        return PastedCells(width: width, height: rows.count, rows: rows)
    }

    static func fitSlice(_ type: NodeType, _ slice: Slice) -> Node? {
        guard let node = type.createAndFill() else { return nil }
        return try? Transform(node).replace(0, node.content.size, slice).doc
    }

    /// Clip or repeat `cells` to cover `newWidth` by `newHeight`.
    public static func clipCells(_ cells: PastedCells, _ newWidth: Int, _ newHeight: Int) -> PastedCells {
        var width = cells.width, height = cells.height, rows = cells.rows
        if width != newWidth {
            var added: [Int: Int] = [:]
            var newRows: [Fragment] = []
            for row in 0..<rows.count {
                let frag = rows[row]
                var result: [Node] = []
                var col = added[row] ?? 0, i = 0
                while col < newWidth && frag.childCount > 0 {
                    var cell = frag.child(i % frag.childCount)
                    if col + cell.colspan > newWidth {
                        cell = (try? cell.type.createChecked(removeColSpan(cell.attrs, cell.colspan, col + cell.colspan - newWidth), cell.content)) ?? cell
                    }
                    result.append(cell)
                    col += cell.colspan
                    if cell.rowspan > 1 { for j in 1..<cell.rowspan { added[row + j, default: 0] += cell.colspan } }
                    i += 1
                }
                newRows.append(Fragment.from(result))
            }
            rows = newRows
            width = newWidth
        }
        if height != newHeight {
            var newRows: [Fragment] = []
            for row in 0..<newHeight {
                let source = rows[row % height]
                var result: [Node] = []
                for j in 0..<source.childCount {
                    var cell = source.child(j)
                    if row + cell.rowspan > newHeight {
                        var attrs = cell.attrs
                        attrs["rowspan"] = max(1, newHeight - cell.rowspan).json
                        cell = makeNode(cell.type, attrs, cell.content)
                    }
                    result.append(cell)
                }
                newRows.append(Fragment.from(result))
            }
            rows = newRows
            height = newHeight
        }
        return PastedCells(width: width, height: height, rows: rows)
    }

    private static func growTable(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int,
                                  _ width: Int, _ height: Int, _ mapFrom: Int) throws -> Bool {
        let types = nodeTypes(tr.doc.type.schema)
        var empty: Node?, emptyHead: Node?
        func cell() -> Node? { if empty == nil { empty = types["cell"]?.createAndFill() }; return empty }
        func head() -> Node? { if emptyHead == nil { emptyHead = types["header_cell"]?.createAndFill() }; return emptyHead }
        if width > map.width {
            var rowEnd = 0
            for row in 0..<map.height {
                let rowNode = table.child(row)
                rowEnd += rowNode.nodeSize
                let add = rowNode.lastChild == nil || rowNode.lastChild!.type === types["cell"] ? cell() : head()
                guard let add else { continue }
                try tr.insert(tr.mapping.slice(mapFrom).map(rowEnd - 1 + start), Array(repeating: add, count: width - map.width))
            }
        }
        if height > map.height {
            var cells: [Node] = []
            let rowStart = (map.height - 1) * map.width
            for i in 0..<max(map.width, width) {
                let header = i >= map.width ? false : table.nodeAt(map.map[rowStart + i])?.type === types["header_cell"]
                if let c = header ? head() : cell() { cells.append(c) }
            }
            let emptyRow = try types["row"]!.create(nil, Fragment.from(cells))
            try tr.insert(tr.mapping.slice(mapFrom).map(start + table.nodeSize - 2),
                          Array(repeating: emptyRow, count: height - map.height))
        }
        return empty != nil || emptyHead != nil
    }

    private static func isolateHorizontal(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int,
                                          _ left: Int, _ right: Int, _ top: Int, _ mapFrom: Int) throws -> Bool {
        if top == 0 || top == map.height { return false }
        var found = false
        var col = left
        while col < right {
            let index = top * map.width + col, pos = map.map[index]
            if map.map[index - map.width] == pos {
                found = true
                let cell = table.nodeAt(pos)!
                let r = map.findCell(pos)
                var attrs = cell.attrs
                attrs["rowspan"] = (top - r.top).json
                try tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + start), attrs: attrs)
                var rest = cell.attrs
                rest["rowspan"] = (r.top + cell.rowspan - top).json
                if let node = cell.type.createAndFill(rest) {
                    try tr.insert(tr.mapping.slice(mapFrom).map(map.positionAt(top, r.left, table)), node)
                }
                col += cell.colspan - 1
            }
            col += 1
        }
        return found
    }

    private static func isolateVertical(_ tr: Transaction, _ map: TableMap, _ table: Node, _ start: Int,
                                        _ top: Int, _ bottom: Int, _ left: Int, _ mapFrom: Int) throws -> Bool {
        if left == 0 || left == map.width { return false }
        var found = false
        var row = top
        while row < bottom {
            let index = row * map.width + left, pos = map.map[index]
            if map.map[index - 1] == pos {
                found = true
                let cell = table.nodeAt(pos)!
                let cellLeft = map.colCount(pos)
                let updatePos = tr.mapping.slice(mapFrom).map(pos + start)
                try tr.setNodeMarkup(updatePos, attrs: removeColSpan(cell.attrs, left - cellLeft, cell.colspan - (left - cellLeft)))
                if let node = cell.type.createAndFill(removeColSpan(cell.attrs, 0, left - cellLeft)) {
                    try tr.insert(updatePos + cell.nodeSize, node)
                }
                row += cell.rowspan - 1
            }
            row += 1
        }
        return found
    }

    /// Insert `cells` into the table starting at `tableStart`, at the top left of `rect`.
    public static func insertCells(_ state: EditorState, _ dispatch: (Transaction) -> Void, _ tableStart: Int,
                                   _ rect: TableRect, _ cells: PastedCells) throws {
        guard var table = tableStart > 0 ? state.doc.nodeAt(tableStart - 1) : state.doc else { throw ProseError.range("No table found") }
        var map = TableMap.get(table)
        let top = rect.top, left = rect.left
        let right = left + cells.width, bottom = top + cells.height
        let tr = state.tr
        var mapFrom = 0
        func recomp() throws {
            guard let t = tableStart > 0 ? tr.doc.nodeAt(tableStart - 1) : tr.doc else { throw ProseError.range("No table found") }
            table = t
            map = TableMap.get(t)
            mapFrom = tr.mapping.maps.count
        }
        if try growTable(tr, map, table, tableStart, right, bottom, mapFrom) { try recomp() }
        if try isolateHorizontal(tr, map, table, tableStart, left, right, top, mapFrom) { try recomp() }
        if try isolateHorizontal(tr, map, table, tableStart, left, right, bottom, mapFrom) { try recomp() }
        if try isolateVertical(tr, map, table, tableStart, top, bottom, left, mapFrom) { try recomp() }
        if try isolateVertical(tr, map, table, tableStart, top, bottom, right, mapFrom) { try recomp() }
        for row in top..<bottom {
            let from = map.positionAt(row, left, table), to = map.positionAt(row, right, table)
            try tr.replace(tr.mapping.slice(mapFrom).map(from + tableStart), tr.mapping.slice(mapFrom).map(to + tableStart),
                           Slice(cells.rows[row - top], openStart: 0, openEnd: 0))
        }
        try recomp()
        tr.setSelection(CellSelection(tr.doc.resolve(tableStart + map.positionAt(top, left, table)),
                                      tr.doc.resolve(tableStart + map.positionAt(bottom - 1, right - 1, table))))
        dispatch(tr)
    }

    /// Paste handler: pasting cells into a table, or anything into a cell selection, fills cells.
    public static func handlePaste(_ view: EditorViewing, _ slice: Slice) -> Bool {
        let state = view.state
        guard isInTable(state) else { return false }
        var cells = pastedCells(slice)
        do {
            if let sel = state.selection as? CellSelection {
                if cells == nil {
                    guard let cell = nodeTypes(state.schema)["cell"], let fitted = fitSlice(cell, slice) else { return false }
                    cells = PastedCells(width: 1, height: 1, rows: [Fragment(fitted)])
                }
                let table = sel.anchorCell.node(-1), start = sel.anchorCell.start(-1)
                let rect = TableMap.get(table).rectBetween(sel.anchorCell.pos - start, sel.headCell.pos - start)
                try insertCells(state, view.dispatch, start, rect, clipCells(cells!, rect.right - rect.left, rect.bottom - rect.top))
                return true
            } else if let cells, let cell = selectionCell(state) {
                let start = cell.start(-1)
                try insertCells(state, view.dispatch, start, TableMap.get(cell.node(-1)).findCell(cell.pos - start), cells)
                return true
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: Keyboard

    private static func maybeSetSelection(_ state: EditorState, _ dispatch: ((Transaction) -> Void)?, _ selection: Selection) -> Bool {
        if selection.eq(state.selection) { return false }
        dispatch?(state.tr.setSelection(selection).scrollIntoView())
        return true
    }

    static func atEndOfCell(_ view: EditorViewing, _ axis: TableAxis, _ dir: Int) -> Int? {
        guard let sel = view.state.selection as? TextSelection else { return nil }
        let head = sel.resolvedHead
        var d = head.depth - 1
        while d >= 0 {
            let parent = head.node(d)
            if (dir < 0 ? head.index(d) : head.indexAfter(d)) != (dir < 0 ? 0 : parent.childCount) { return nil }
            if parent.isCellNode {
                let cellPos = head.before(d)
                let dirName: TextDirection = axis == .vertical ? (dir > 0 ? .down : .up) : (dir > 0 ? .right : .left)
                let atEnd = view.endOfTextblock(dirName, view.state)
                    ?? (dir > 0 ? head.parentOffset == head.parent.content.size : head.parentOffset == 0)
                return atEnd ? cellPos : nil
            }
            d -= 1
        }
        return nil
    }

    /// Arrow key command that moves out of cells and cell selections.
    public static func arrow(_ axis: TableAxis, _ dir: Int) -> Command {
        return { state, dispatch, view in
            guard let view else { return false }
            let sel = state.selection
            if let cells = sel as? CellSelection { return maybeSetSelection(state, dispatch, Selection.near(cells.headCell, bias: dir)) }
            if axis != .horizontal && !sel.isEmpty { return false }
            guard let end = atEndOfCell(view, axis, dir) else { return false }
            if axis == .horizontal {
                return maybeSetSelection(state, dispatch, Selection.near(state.doc.resolve(sel.head + dir), bias: dir))
            }
            let cell = state.doc.resolve(end)
            let newSel: Selection
            if let next = nextCell(cell, axis, dir) { newSel = Selection.near(next, bias: 1) }
            else if dir < 0 { newSel = Selection.near(state.doc.resolve(cell.before(-1)), bias: -1) }
            else { newSel = Selection.near(state.doc.resolve(cell.after(-1)), bias: 1) }
            return maybeSetSelection(state, dispatch, newSel)
        }
    }

    /// Shift-arrow command that extends a cell selection.
    public static func shiftArrow(_ axis: TableAxis, _ dir: Int) -> Command {
        return { state, dispatch, view in
            guard let view else { return false }
            let cellSel: CellSelection
            if let cells = state.selection as? CellSelection { cellSel = cells }
            else {
                guard let end = atEndOfCell(view, axis, dir) else { return false }
                cellSel = CellSelection(state.doc.resolve(end))
            }
            guard let head = nextCell(cellSel.headCell, axis, dir) else { return false }
            return maybeSetSelection(state, dispatch, CellSelection(cellSel.anchorCell, head))
        }
    }

    /// The table key bindings.
    public static let keymap: [String: Command] = [
        "ArrowLeft": arrow(.horizontal, -1), "ArrowRight": arrow(.horizontal, 1),
        "ArrowUp": arrow(.vertical, -1), "ArrowDown": arrow(.vertical, 1),
        "Shift-ArrowLeft": shiftArrow(.horizontal, -1), "Shift-ArrowRight": shiftArrow(.horizontal, 1),
        "Shift-ArrowUp": shiftArrow(.vertical, -1), "Shift-ArrowDown": shiftArrow(.vertical, 1),
        "Backspace": TableCommands.deleteCellSelection, "Mod-Backspace": TableCommands.deleteCellSelection,
        "Delete": TableCommands.deleteCellSelection, "Mod-Delete": TableCommands.deleteCellSelection,
    ]

    /// Select the cell at `pos` on triple click.
    public static func handleTripleClick(_ view: EditorViewing, _ pos: Int) -> Bool {
        guard let cell = cellAround(view.state.doc.resolve(pos)) else { return false }
        view.dispatch(view.state.tr.setSelection(CellSelection(cell)))
        return true
    }

    // MARK: Plugin

    /// Plugin state: the anchor cell position while a mouse cell selection is in progress.
    public static let editingKey = PluginKey<Int?>("selectingCells")

    /// Mouse cell selection: the view calls this while dragging from the cell at `anchor` to the
    /// cell at `head` (both positions in front of a cell). Pass nil for `head` when the mouse is
    /// outside the table.
    public static func dragCellSelection(_ view: EditorViewing, anchor: ResolvedPos, head: ResolvedPos?) {
        let starting = (editingKey.getState(view.state) ?? nil) == nil
        var head = head
        if head == nil || !inSameTable(anchor, head!) {
            if starting { head = anchor } else { return }
        }
        let selection = CellSelection(anchor, head!)
        if starting || !view.state.selection.eq(selection) {
            let tr = view.state.tr.setSelection(selection)
            if starting { tr.setMeta(editingKey, anchor.pos) }
            view.dispatch(tr)
        }
    }

    /// Ends a mouse cell selection started with ``dragCellSelection(_:anchor:head:)``.
    public static func endCellDrag(_ view: EditorViewing) {
        if (editingKey.getState(view.state) ?? nil) != nil { view.dispatch(view.state.tr.setMeta(editingKey, -1)) }
    }

    /// The table editing plugin: cell selections, cell-aware paste and key handling, and
    /// keeping tables well-formed. Put it near the end of the plugin list.
    public static func editing(allowTableNodeSelection: Bool = false) -> Plugin {
        CellSelection.registerJSON()
        var props = EditorProps()
        props.handleKeyDown = Keymap.handler(keymap)
        props.handlePaste = handlePaste
        props.handleTripleClick = handleTripleClick
        props.createSelectionBetween = { view, _, _ in
            (editingKey.getState(view.state) ?? nil) != nil ? view.state.selection : nil
        }
        let field = StateField<Int?>(
            initialize: { _, _ in nil },
            apply: { tr, cur, _, _ in
                if let set = tr.getMeta(editingKey) as? Int { return set == -1 ? nil : set }
                guard let cur, tr.docChanged else { return cur }
                let result = tr.mapping.mapResult(cur, assoc: 1)
                return result.deleted ? nil : result.pos
            })
        return Plugin(key: editingKey, state: field, props: props,
                      appendTransaction: { _, oldState, state in
                          normalizeSelection(state, fixTables(state, oldState: oldState),
                                             allowTableNodeSelection: allowTableNodeSelection)
                      },
                      extra: ["tableEditing": true])
    }
}
