/// The selected rectangle in a table, with the table's map, node and start position.
public struct SelectedRect {
    public var left: Int, top: Int, right: Int, bottom: Int
    public var tableStart: Int
    public var map: TableMap
    public var table: Node
    public var rect: TableRect { TableRect(left: left, top: top, right: right, bottom: bottom) }
}

private func build(_ f: () throws -> Void) -> Bool {
    do { try f(); return true } catch { return false }
}

/// Table editing commands. Port of the commands in prosemirror-tables.
public enum TableCommands {
    /// The selected rectangle, or nil when the selection is not in a table.
    public static func selectedRect(_ state: EditorState) -> SelectedRect? {
        guard let pos = Tables.selectionCell(state), pos.depth > 0 else { return nil }
        let table = pos.node(-1), tableStart = pos.start(-1)
        let map = TableMap.get(table)
        let r: TableRect
        if let cells = state.selection as? CellSelection {
            r = map.rectBetween(cells.anchorCell.pos - tableStart, cells.headCell.pos - tableStart)
        } else {
            r = map.findCell(pos.pos - tableStart)
        }
        return SelectedRect(left: r.left, top: r.top, right: r.right, bottom: r.bottom, tableStart: tableStart, map: map, table: table)
    }

    // MARK: Columns

    /// Add a column at index `col`.
    @discardableResult
    public static func addColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) throws -> Transaction {
        let map = rect.map, table = rect.table, tableStart = rect.tableStart
        var refColumn: Int? = col > 0 ? -1 : 0
        if Tables.columnIsHeader(map, table, col + refColumn!) { refColumn = col == 0 || col == map.width ? nil : 0 }
        var row = 0
        while row < map.height {
            let index = row * map.width + col
            if col > 0 && col < map.width && map.map[index - 1] == map.map[index] {
                let pos = map.map[index]
                let cell = table.nodeAt(pos)!
                try tr.setNodeMarkup(tr.mapping.map(tableStart + pos), attrs: Tables.addColSpan(cell.attrs, col - map.colCount(pos)))
                row += cell.rowspan - 1
            } else {
                let type = refColumn.map { table.nodeAt(map.map[index + $0])!.type } ?? Tables.nodeTypes(table.type.schema)["cell"]!
                let pos = map.positionAt(row, col, table)
                if let node = type.createAndFill() { try tr.insert(tr.mapping.map(tableStart + pos), node) }
            }
            row += 1
        }
        return tr
    }

    /// Add a column before the column with the selection.
    public static let addColumnBefore: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        if let dispatch, let rect = selectedRect(state) {
            return build { dispatch(try addColumn(state.tr, rect, rect.left)) }
        }
        return true
    }

    /// Add a column after the column with the selection.
    public static let addColumnAfter: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        if let dispatch, let rect = selectedRect(state) {
            return build { dispatch(try addColumn(state.tr, rect, rect.right)) }
        }
        return true
    }

    /// Remove column `col`.
    public static func removeColumn(_ tr: Transaction, _ rect: SelectedRect, _ col: Int) throws {
        let map = rect.map, table = rect.table, tableStart = rect.tableStart
        let mapStart = tr.mapping.maps.count
        var row = 0
        while row < map.height {
            let index = row * map.width + col
            let pos = map.map[index]
            let cell = table.nodeAt(pos)!
            if (col > 0 && map.map[index - 1] == pos) || (col < map.width - 1 && map.map[index + 1] == pos) {
                try tr.setNodeMarkup(tr.mapping.slice(mapStart).map(tableStart + pos),
                                     attrs: Tables.removeColSpan(cell.attrs, col - map.colCount(pos)))
            } else {
                let start = tr.mapping.slice(mapStart).map(tableStart + pos)
                try tr.delete(start, start + cell.nodeSize)
            }
            row += max(cell.rowspan, 1)
        }
    }

    /// Remove the selected columns. Fails when every column is selected.
    public static let deleteColumn: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        guard let dispatch, var rect = selectedRect(state) else { return true }
        if rect.left == 0 && rect.right == rect.map.width { return false }
        let tr = state.tr
        return build {
            var i = rect.right - 1
            while true {
                try removeColumn(tr, rect, i)
                if i == rect.left { break }
                guard let table = rect.tableStart > 0 ? tr.doc.nodeAt(rect.tableStart - 1) : tr.doc else {
                    throw ProseError.range("No table found")
                }
                rect.table = table
                rect.map = TableMap.get(table)
                i -= 1
            }
            dispatch(tr)
        }
    }

    // MARK: Rows

    /// Add a row at index `row`.
    @discardableResult
    public static func addRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) throws -> Transaction {
        let map = rect.map, table = rect.table, tableStart = rect.tableStart
        var rowPos = tableStart
        for i in 0..<row { rowPos += table.child(i).nodeSize }
        var cells: [Node] = []
        var refRow: Int? = row > 0 ? -1 : 0
        if Tables.rowIsHeader(map, table, row + refRow!) { refRow = row == 0 || row == map.height ? nil : 0 }
        var col = 0, index = map.width * row
        while col < map.width {
            if row > 0 && row < map.height && map.map[index] == map.map[index - map.width] {
                let pos = map.map[index]
                var attrs = table.nodeAt(pos)!.attrs
                attrs["rowspan"] = (attrs.rowspan + 1).json
                try tr.setNodeMarkup(tableStart + pos, attrs: attrs)
                col += attrs.colspan - 1
            } else {
                let type = refRow.map { table.nodeAt(map.map[index + $0 * map.width])?.type }
                    ?? Tables.nodeTypes(table.type.schema)["cell"]
                // Keep the column alignment (GFM tables) of the adjacent row.
                let neighbor = table.nodeAt(map.map[row > 0 ? index - map.width : index])
                var attrs: Attrs?
                if let type, type.attrs["alignment"] != nil, let a = neighbor?.attrs["alignment"] { attrs = ["alignment": a] }
                if let node = type?.createAndFill(attrs) { cells.append(node) }
            }
            col += 1; index += 1
        }
        try tr.insert(rowPos, try Tables.nodeTypes(table.type.schema)["row"]!.create(nil, cells))
        return tr
    }

    /// Add a row before the selection.
    public static let addRowBefore: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        if let dispatch, let rect = selectedRect(state) {
            return build { dispatch(try addRow(state.tr, rect, rect.top)) }
        }
        return true
    }

    /// Add a row after the selection.
    public static let addRowAfter: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        if let dispatch, let rect = selectedRect(state) {
            return build { dispatch(try addRow(state.tr, rect, rect.bottom)) }
        }
        return true
    }

    /// Remove row `row`.
    public static func removeRow(_ tr: Transaction, _ rect: SelectedRect, _ row: Int) throws {
        let map = rect.map, table = rect.table, tableStart = rect.tableStart
        var rowPos = 0
        for i in 0..<row { rowPos += table.child(i).nodeSize }
        let nextRow = rowPos + table.child(row).nodeSize
        let mapFrom = tr.mapping.maps.count
        try tr.delete(rowPos + tableStart, nextRow + tableStart)
        var seen = Set<Int>()
        var col = 0, index = row * map.width
        while col < map.width {
            defer { col += 1; index += 1 }
            let pos = map.map[index]
            if seen.contains(pos) { continue }
            seen.insert(pos)
            if row > 0 && pos == map.map[index - map.width] {
                var attrs = table.nodeAt(pos)!.attrs
                attrs["rowspan"] = (attrs.rowspan - 1).json
                try tr.setNodeMarkup(tr.mapping.slice(mapFrom).map(pos + tableStart), attrs: attrs)
                col += attrs.colspan - 1
            } else if row < map.height - 1 && pos == map.map[index + map.width] {
                let cell = table.nodeAt(pos)!
                var attrs = cell.attrs
                attrs["rowspan"] = (cell.rowspan - 1).json
                let copy = try cell.type.create(attrs, cell.content)
                let newPos = map.positionAt(row + 1, col, table)
                try tr.insert(tr.mapping.slice(mapFrom).map(tableStart + newPos), copy)
                col += attrs.colspan - 1
            }
        }
    }

    /// Remove the selected rows. Fails when every row is selected.
    public static let deleteRow: Command = { state, dispatch, _ in
        guard Tables.isInTable(state) else { return false }
        guard let dispatch, var rect = selectedRect(state) else { return true }
        if rect.top == 0 && rect.bottom == rect.map.height { return false }
        let tr = state.tr
        return build {
            var i = rect.bottom - 1
            while true {
                try removeRow(tr, rect, i)
                if i == rect.top { break }
                guard let table = rect.tableStart > 0 ? tr.doc.nodeAt(rect.tableStart - 1) : tr.doc else {
                    throw ProseError.range("No table found")
                }
                rect.table = table
                rect.map = TableMap.get(table)
                i -= 1
            }
            dispatch(tr)
        }
    }

    // MARK: Merging and splitting

    private static func isEmpty(_ cell: Node) -> Bool {
        let c = cell.content
        return c.childCount == 1 && c.child(0).isTextblock && c.child(0).childCount == 0
    }

    private static func cellsOverlapRectangle(_ m: TableMap, _ rect: SelectedRect) -> Bool {
        let width = m.width, height = m.height, map = m.map
        var indexTop = rect.top * width + rect.left, indexLeft = indexTop
        var indexBottom = (rect.bottom - 1) * width + rect.left, indexRight = indexTop + (rect.right - rect.left - 1)
        for _ in rect.top..<rect.bottom {
            if (rect.left > 0 && map[indexLeft] == map[indexLeft - 1]) ||
                (rect.right < width && map[indexRight] == map[indexRight + 1]) { return true }
            indexLeft += width; indexRight += width
        }
        for _ in rect.left..<rect.right {
            if (rect.top > 0 && map[indexTop] == map[indexTop - width]) ||
                (rect.bottom < height && map[indexBottom] == map[indexBottom + width]) { return true }
            indexTop += 1; indexBottom += 1
        }
        return false
    }

    /// Merge the selected cells into one. Only available when their outline is a rectangle.
    public static let mergeCells: Command = { state, dispatch, _ in
        guard let sel = state.selection as? CellSelection, sel.anchorCell.pos != sel.headCell.pos,
              let rect = selectedRect(state) else { return false }
        let map = rect.map
        if cellsOverlapRectangle(map, rect) { return false }
        guard let dispatch else { return true }
        let tr = state.tr
        return build {
            var seen = Set<Int>()
            var content = Fragment.empty
            var merged: (pos: Int, cell: Node)?
            for row in rect.top..<rect.bottom {
                for col in rect.left..<rect.right {
                    let cellPos = map.map[row * map.width + col]
                    guard !seen.contains(cellPos), let cell = rect.table.nodeAt(cellPos) else { continue }
                    seen.insert(cellPos)
                    if merged == nil {
                        merged = (cellPos, cell)
                    } else {
                        if !isEmpty(cell) { content = content.append(cell.content) }
                        let mapped = tr.mapping.map(cellPos + rect.tableStart)
                        try tr.delete(mapped, mapped + cell.nodeSize)
                    }
                }
            }
            guard let (mergedPos, mergedCell) = merged else { return }
            var attrs = Tables.addColSpan(mergedCell.attrs, mergedCell.colspan, rect.right - rect.left - mergedCell.colspan)
            attrs["rowspan"] = (rect.bottom - rect.top).json
            try tr.setNodeMarkup(mergedPos + rect.tableStart, attrs: attrs)
            if content.size > 0 {
                let end = mergedPos + 1 + mergedCell.content.size
                let start = isEmpty(mergedCell) ? mergedPos + 1 : end
                try tr.replaceWith(start + rect.tableStart, end + rect.tableStart, content)
            }
            tr.setSelection(CellSelection(tr.doc.resolve(mergedPos + rect.tableStart)))
            dispatch(tr)
        }
    }

    /// Split a selected cell with a rowspan or colspan above one into single cells of the same type.
    public static let splitCell: Command = { state, dispatch, view in
        let types = Tables.nodeTypes(state.schema)
        return splitCell(cellType: { node, _, _ in types[node.type.tableRole ?? "cell"]! })(state, dispatch, view)
    }

    /// Split a selected cell, using `cellType` to pick the type of each resulting cell.
    public static func splitCell(cellType: @escaping (_ node: Node, _ row: Int, _ col: Int) -> NodeType) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection
            let cellNode: Node, cellPos: Int
            if let cells = sel as? CellSelection {
                if cells.anchorCell.pos != cells.headCell.pos { return false }
                guard let node = cells.anchorCell.nodeAfter else { return false }
                cellNode = node; cellPos = cells.anchorCell.pos
            } else {
                guard let node = Tables.cellWrapping(sel.resolvedFrom), let pos = Tables.cellAround(sel.resolvedFrom)?.pos else { return false }
                cellNode = node; cellPos = pos
            }
            if cellNode.colspan == 1 && cellNode.rowspan == 1 { return false }
            guard let dispatch else { return true }
            guard let rect = selectedRect(state) else { return false }
            let tr = state.tr
            return build {
                var baseAttrs = cellNode.attrs
                let colwidth = baseAttrs["colwidth"]?.arrayValue
                if baseAttrs.rowspan > 1 { baseAttrs["rowspan"] = 1 }
                if baseAttrs.colspan > 1 { baseAttrs["colspan"] = 1 }
                var attrs: [Attrs] = []
                for i in 0..<(rect.right - rect.left) {
                    if let colwidth {
                        var a = baseAttrs
                        if let w = colwidth[safe: i], (w.doubleValue ?? 0) != 0 { a["colwidth"] = [w] } else { a["colwidth"] = .null }
                        attrs.append(a)
                    } else {
                        attrs.append(baseAttrs)
                    }
                }
                var lastCell: Int?
                for row in rect.top..<rect.bottom {
                    var pos = rect.map.positionAt(row, rect.left, rect.table)
                    if row == rect.top { pos += cellNode.nodeSize }
                    var i = 0
                    for col in rect.left..<rect.right {
                        defer { i += 1 }
                        if col == rect.left && row == rect.top { continue }
                        let at = tr.mapping.map(pos + rect.tableStart, assoc: 1)
                        lastCell = at
                        if let node = cellType(cellNode, row, col).createAndFill(attrs[i]) { try tr.insert(at, node) }
                    }
                }
                try tr.setNodeMarkup(cellPos, type: cellType(cellNode, rect.top, rect.left), attrs: attrs[0])
                if let cells = sel as? CellSelection {
                    tr.setSelection(CellSelection(tr.doc.resolve(cells.anchorCell.pos), lastCell.map { tr.doc.resolve($0) }))
                }
                dispatch(tr)
            }
        }
    }

    // MARK: Attributes and headers

    /// Set attribute `name` to `value` on the selected cells. Fails when the cell already has it.
    public static func setCellAttr(_ name: String, _ value: JSON) -> Command {
        return { state, dispatch, _ in
            guard Tables.isInTable(state), let cell = Tables.selectionCell(state), let node = cell.nodeAfter else { return false }
            if (node.attrs[name] ?? .null) == value { return false }
            guard let dispatch else { return true }
            let tr = state.tr
            return build {
                if let cells = state.selection as? CellSelection {
                    var failure: Error?
                    cells.forEachCell { node, pos in
                        guard failure == nil, (node.attrs[name] ?? .null) != value else { return }
                        var attrs = node.attrs
                        attrs[name] = value
                        do { try tr.setNodeMarkup(pos, attrs: attrs) } catch { failure = error }
                    }
                    if let failure { throw failure }
                } else {
                    var attrs = node.attrs
                    attrs[name] = value
                    try tr.setNodeMarkup(cell.pos, attrs: attrs)
                }
                dispatch(tr)
            }
        }
    }

    /// Which cells ``toggleHeader(_:useDeprecatedLogic:)`` toggles.
    public enum HeaderType { case row, column, cell }

    private static func deprecatedToggleHeader(_ type: HeaderType) -> Command {
        return { state, dispatch, _ in
            guard Tables.isInTable(state) else { return false }
            guard let dispatch, let rect = selectedRect(state) else { return true }
            let types = Tables.nodeTypes(state.schema)
            let tr = state.tr
            return build {
                let cells = rect.map.cellsInRect(
                    type == .column ? TableRect(left: rect.left, top: 0, right: rect.right, bottom: rect.map.height)
                        : type == .row ? TableRect(left: 0, top: rect.top, right: rect.map.width, bottom: rect.bottom)
                        : rect.rect)
                let nodes = cells.map { rect.table.nodeAt($0)! }
                for (i, node) in nodes.enumerated() where node.type === types["header_cell"] {
                    try tr.setNodeMarkup(rect.tableStart + cells[i], type: types["cell"], attrs: node.attrs)
                }
                if tr.steps.isEmpty {
                    for (i, node) in nodes.enumerated() {
                        try tr.setNodeMarkup(rect.tableStart + cells[i], type: types["header_cell"], attrs: node.attrs)
                    }
                }
                dispatch(tr)
            }
        }
    }

    private static func isHeaderEnabled(_ type: HeaderType, _ rect: SelectedRect, _ types: [String: NodeType]) -> Bool {
        let cells = rect.map.cellsInRect(TableRect(left: 0, top: 0, right: type == .row ? rect.map.width : 1,
                                                   bottom: type == .column ? rect.map.height : 1))
        for pos in cells {
            if let cell = rect.table.nodeAt(pos), cell.type !== types["header_cell"] { return false }
        }
        return true
    }

    /// Toggle header cells. The default logic only toggles the first row or column; with
    /// `useDeprecatedLogic`, the selected rows, columns or cells are toggled.
    public static func toggleHeader(_ type: HeaderType, useDeprecatedLogic: Bool = false) -> Command {
        if useDeprecatedLogic { return deprecatedToggleHeader(type) }
        return { state, dispatch, _ in
            guard Tables.isInTable(state) else { return false }
            guard let dispatch, let rect = selectedRect(state) else { return true }
            let types = Tables.nodeTypes(state.schema)
            let tr = state.tr
            return build {
                let rowEnabled = isHeaderEnabled(.row, rect, types), colEnabled = isHeaderEnabled(.column, rect, types)
                let startsAt = (type == .column ? rowEnabled : type == .row ? colEnabled : false) ? 1 : 0
                let cellsRect = type == .column ? TableRect(left: 0, top: startsAt, right: 1, bottom: rect.map.height)
                    : type == .row ? TableRect(left: startsAt, top: 0, right: rect.map.width, bottom: 1) : rect.rect
                let newType = type == .column ? (colEnabled ? types["cell"] : types["header_cell"])
                    : type == .row ? (rowEnabled ? types["cell"] : types["header_cell"]) : types["cell"]
                for relative in rect.map.cellsInRect(cellsRect) {
                    let cellPos = relative + rect.tableStart
                    if let cell = tr.doc.nodeAt(cellPos) { try tr.setNodeMarkup(cellPos, type: newType, attrs: cell.attrs) }
                }
                dispatch(tr)
            }
        }
    }

    /// Toggle whether the selected row contains header cells.
    public static let toggleHeaderRow = toggleHeader(.row, useDeprecatedLogic: true)
    /// Toggle whether the selected column contains header cells.
    public static let toggleHeaderColumn = toggleHeader(.column, useDeprecatedLogic: true)
    /// Toggle whether the selected cells are header cells.
    public static let toggleHeaderCell = toggleHeader(.cell, useDeprecatedLogic: true)

    // MARK: Navigation and deletion

    static func findNextCell(_ cell: ResolvedPos, _ dir: Int) -> Int? {
        if dir < 0 {
            if let before = cell.nodeBefore { return cell.pos - before.nodeSize }
            var row = cell.index(-1) - 1, rowEnd = cell.before()
            while row >= 0 {
                let rowNode = cell.node(-1).child(row)
                if let last = rowNode.lastChild { return rowEnd - 1 - last.nodeSize }
                rowEnd -= rowNode.nodeSize
                row -= 1
            }
        } else {
            if cell.index() < cell.parent.childCount - 1 { return cell.pos + cell.nodeAfter!.nodeSize }
            let table = cell.node(-1)
            var row = cell.indexAfter(-1), rowStart = cell.after()
            while row < table.childCount {
                let rowNode = table.child(row)
                if rowNode.childCount > 0 { return rowStart + 1 }
                rowStart += rowNode.nodeSize
                row += 1
            }
        }
        return nil
    }

    /// Select the content of the next (`1`) or previous (`-1`) cell.
    public static func goToNextCell(_ direction: Int) -> Command {
        return { state, dispatch, _ in
            guard Tables.isInTable(state), let current = Tables.selectionCell(state),
                  let cell = findNextCell(current, direction) else { return false }
            if let dispatch {
                let pos = state.doc.resolve(cell)
                dispatch(state.tr.setSelection(TextSelection.between(pos, Tables.moveCellForward(pos))).scrollIntoView())
            }
            return true
        }
    }

    /// Delete the table around the selection.
    public static let deleteTable: Command = { state, dispatch, _ in
        let pos = state.selection.resolvedAnchor
        var d = pos.depth
        while d > 0 {
            if pos.node(d).type.tableRole == "table" {
                if let dispatch { return build { dispatch(try state.tr.delete(pos.before(d), pos.after(d)).scrollIntoView()) } }
                return true
            }
            d -= 1
        }
        return false
    }

    /// Clear the content of the selected cells.
    public static let deleteCellSelection: Command = { state, dispatch, _ in
        guard let sel = state.selection as? CellSelection else { return false }
        guard let dispatch else { return true }
        guard let base = Tables.nodeTypes(state.schema)["cell"]?.createAndFill()?.content else { return true }
        let tr = state.tr
        var failed = false
        sel.forEachCell { cell, pos in
            if failed || cell.content.eq(base) { return }
            do { try tr.replace(tr.mapping.map(pos + 1), tr.mapping.map(pos + cell.nodeSize - 1), Slice(base, openStart: 0, openEnd: 0)) }
            catch { failed = true }
        }
        if !failed && tr.docChanged { dispatch(tr) }
        return true
    }

    // MARK: Moving rows and columns

    /// Move row `from` to index `to`. `pos` picks the table (default: the selection start).
    public static func moveTableRow(from: Int, to: Int, select: Bool = true, pos: Int? = nil) -> Command {
        return { state, dispatch, _ in
            let tr = state.tr
            guard (try? TableMoves.move(tr, rows: true, from, to, select, pos ?? state.selection.from)) == true else { return false }
            dispatch?(tr)
            return true
        }
    }

    /// Move column `from` to index `to`. `pos` picks the table (default: the selection start).
    public static func moveTableColumn(from: Int, to: Int, select: Bool = true, pos: Int? = nil) -> Command {
        return { state, dispatch, _ in
            let tr = state.tr
            guard (try? TableMoves.move(tr, rows: false, from, to, select, pos ?? state.selection.from)) == true else { return false }
            dispatch?(tr)
            return true
        }
    }
}

enum TableMoves {
    struct CellInfo { let pos: Int; let node: Node }

    static func cells(_ selection: Selection, row: Int? = nil, column: Int? = nil) -> [CellInfo]? {
        guard let table = Tables.findTable(selection.resolvedFrom) else { return nil }
        let map = TableMap.get(table.node)
        let rect: TableRect
        if let column {
            if column < 0 || column > map.width - 1 { return nil }
            rect = TableRect(left: column, top: 0, right: column + 1, bottom: map.height)
        } else {
            let row = row!
            if row < 0 || row > map.height - 1 { return nil }
            rect = TableRect(left: 0, top: row, right: map.width, bottom: row + 1)
        }
        return map.cellsInRect(rect).map { CellInfo(pos: $0 + table.start, node: table.node.nodeAt($0)!) }
    }

    /// The indexes of the rows (or columns) spanned by merged cells around `start`.
    static func rangeIndexes(_ tr: Transaction, rows: Bool, _ start: Int) -> [Int]? {
        func line(_ i: Int) -> [CellInfo]? { rows ? cells(tr.selection, row: i) : cells(tr.selection, column: i) }
        func span(_ c: CellInfo) -> Int { rows ? c.node.rowspan : c.node.colspan }
        var startIndex = start, endIndex = start
        var i = start
        while i >= 0 {
            for cell in line(i) ?? [] {
                let maybeEnd = span(cell) + i - 1
                if maybeEnd >= startIndex { startIndex = i }
                if maybeEnd > endIndex { endIndex = maybeEnd }
            }
            i -= 1
        }
        i = start
        while i <= endIndex {
            for cell in line(i) ?? [] {
                let maybeEnd = span(cell) + i - 1
                if span(cell) > 1 && maybeEnd > endIndex { endIndex = maybeEnd }
            }
            i += 1
        }
        var indexes: [Int] = []
        if startIndex <= endIndex {
            for i in startIndex...endIndex where !(line(i) ?? []).isEmpty { indexes.append(i) }
        }
        guard let first = indexes.first, let last = indexes.last else { return nil }
        // The JS version also looks for anchor and head cells and fails when they are missing.
        guard let firstSelected = line(first), !firstSelected.isEmpty,
              let crossLine = rows ? cells(tr.selection, column: 0) : cells(tr.selection, row: 0) else { return nil }
        var found = false
        var k = last
        while k >= first && !found {
            if let lineCells = line(k), let head = lineCells.first {
                found = crossLine.contains { $0.pos == head.pos }
            }
            k -= 1
        }
        return found ? indexes : nil
    }

    static func moveInArray<T>(_ rows: [T], _ origin: [Int], _ target: [Int], _ directionOverride: Int) -> [T] {
        var rows = rows
        let direction = origin[0] > target[0] ? -1 : 1
        let extracted = Array(rows[origin[0]..<min(origin[0] + origin.count, rows.count)])
        rows.removeSubrange(origin[0]..<min(origin[0] + origin.count, rows.count))
        let positionOffset = extracted.count % 2 == 0 ? 1 : 0
        let targetIndex: Int
        if directionOverride == -1 && direction == 1 { targetIndex = target[0] - 1 }
        else if directionOverride == 1 && direction == -1 { targetIndex = target[target.count - 1] - positionOffset + 1 }
        else { targetIndex = direction == -1 ? target[0] : target[target.count - 1] - positionOffset }
        rows.insert(contentsOf: extracted, at: min(max(targetIndex, 0), rows.count))
        return rows
    }

    static func toArray(_ table: Node) -> [[Node?]] {
        let map = TableMap.get(table)
        var rows: [[Node?]] = []
        for r in 0..<map.height {
            var row: [Node?] = []
            for c in 0..<map.width {
                let index = r * map.width + c, pos = map.map[index]
                if (r > 0 && pos == map.map[index - map.width]) || (c > 0 && pos == map.map[index - 1]) { row.append(nil); continue }
                row.append(table.nodeAt(pos))
            }
            rows.append(row)
        }
        return rows
    }

    static func fromArray(_ table: Node, _ array: [[Node?]]) throws -> Node {
        let map = TableMap.get(table)
        var newRows: [Node] = []
        for r in 0..<map.height {
            let oldRow = table.child(r)
            var newCells: [Node] = []
            for c in 0..<map.width {
                guard let cell = array[r][c], let old = table.nodeAt(map.map[r * map.width + c]) else { continue }
                newCells.append(try old.type.createChecked(cell.attrs, cell.content, marks: cell.marks))
            }
            newRows.append(try oldRow.type.createChecked(oldRow.attrs, Fragment.from(newCells), marks: oldRow.marks))
        }
        return try table.type.createChecked(table.attrs, Fragment.from(newRows), marks: table.marks)
    }

    static func transpose<T>(_ a: [[T]]) -> [[T]] {
        guard let first = a.first else { return a }
        return first.indices.map { i in a.map { $0[i] } }
    }

    static func move(_ tr: Transaction, rows: Bool, _ origin: Int, _ target: Int, _ select: Bool, _ pos: Int) throws -> Bool {
        guard let table = Tables.findTable(tr.doc.resolve(pos)) else { return false }
        guard let originIdx = rangeIndexes(tr, rows: rows, origin), let targetIdx = rangeIndexes(tr, rows: rows, target) else { return false }
        if originIdx.contains(target) { return false }
        var array = toArray(table.node)
        if rows {
            array = moveInArray(array, originIdx, targetIdx, 0)
        } else {
            array = transpose(moveInArray(transpose(array), originIdx, targetIdx, 0))
        }
        let newTable = try fromArray(table.node, array)
        try tr.replaceWith(table.pos, table.pos + table.node.nodeSize, newTable)
        if !select { return true }
        let map = TableMap.get(newTable)
        if rows {
            let last = tr.doc.resolve(table.start + map.positionAt(target, map.width - 1, newTable))
            let first = tr.doc.resolve(table.start + map.positionAt(target, 0, newTable))
            tr.setSelection(CellSelection.rowSelection(last, first))
        } else {
            let last = tr.doc.resolve(table.start + map.positionAt(map.height - 1, target, newTable))
            let first = tr.doc.resolve(table.start + map.positionAt(0, target, newTable))
            tr.setSelection(CellSelection.colSelection(last, first))
        }
        return true
    }
}
