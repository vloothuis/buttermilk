import XCTest
@testable import ButtermilkCore

let tableSchema: Schema = try! Schema(
    nodeList: ListSchema.addListNodes(BasicSchema.nodes, itemContent: "paragraph block*", listGroup: "block")
        + Tables.nodes(cellContent: "block+", cellAttributes: ["background": .init(default: .null)], tableGroup: "block"),
    markList: BasicSchema.marks)

final class TablesGoldenTests: XCTestCase {
    static let fixture = loadFixture("tables")
    let schema = tableSchema
    /// The state a chained command dispatches against, when it is not the starting state.
    var chainBase: EditorState?

    lazy var commands: [String: Command] = [
        "addColumnBefore": TableCommands.addColumnBefore, "addColumnAfter": TableCommands.addColumnAfter,
        "deleteColumn": TableCommands.deleteColumn, "addRowBefore": TableCommands.addRowBefore,
        "addRowAfter": TableCommands.addRowAfter, "deleteRow": TableCommands.deleteRow,
        "mergeCells": TableCommands.mergeCells, "splitCell": TableCommands.splitCell,
        "setBackground": TableCommands.setCellAttr("background", "red"),
        "toggleHeaderRow": TableCommands.toggleHeaderRow, "toggleHeaderColumn": TableCommands.toggleHeaderColumn,
        "toggleHeaderCell": TableCommands.toggleHeaderCell,
        "toggleRow": TableCommands.toggleHeader(.row), "toggleColumn": TableCommands.toggleHeader(.column),
        "nextCell": TableCommands.goToNextCell(1), "prevCell": TableCommands.goToNextCell(-1),
        "deleteTable": TableCommands.deleteTable, "deleteCellSelection": TableCommands.deleteCellSelection,
        "moveRow01": TableCommands.moveTableRow(from: 0, to: 1), "moveRow10": TableCommands.moveTableRow(from: 1, to: 0),
        "moveCol01": TableCommands.moveTableColumn(from: 0, to: 1), "moveCol20": TableCommands.moveTableColumn(from: 2, to: 0),
        "mergeSplit": { state, dispatch, view in
            var merged: EditorState?
            guard TableCommands.mergeCells(state, { merged = try! state.apply($0) }, view), let merged else { return false }
            self.chainBase = merged
            return TableCommands.splitCell(merged, dispatch, view)
        },
    ]

    func keyPress(_ spec: String) -> KeyPress {
        spec.hasPrefix("Shift-") ? KeyPress(String(spec.dropFirst(6)), modifiers: .shift) : KeyPress(spec)
    }

    func testTables() throws {
        let plugin = Tables.editing()
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["cases"]!.array.enumerated() {
            let raw = try schema.nodeFromJSON(c["raw"]!)
            var maps: [JSON] = []
            raw.descendants { node, _, _, _ in
                if node.type.tableRole == "table" {
                    let map = TableMap.get(node)
                    maps.append(["width": map.width.json, "height": map.height.json, "map": .array(map.map.map(\.json)),
                                 "problems": map.problems.map { .array($0.map { $0.toJSON() }) } ?? .null])
                }
                return true
            }
            total += 1
            m.equal(.array(maps), c["maps"]!, "case \(ci) maps")
            let fixTr = Tables.fixTables(try EditorState.create(.init(doc: raw)))
            total += 1
            m.equal(fixTr?.doc.toJSON() ?? .null, c["fixed"]!, "case \(ci) fixTables")
            let doc = fixTr?.doc ?? raw

            for (oi, op) in c["ops"]!.array.enumerated() {
                total += 1
                let sel = try Selection.fromJSON(doc, op["sel"]!)
                let state = try EditorState.create(.init(doc: doc, selection: sel, plugins: [plugin]))
                var got: [String: JSON] = ["sel": op["sel"]!, "state": state.selection.toJSON()]
                var label = ""
                if let name = op["command"]?.stringValue {
                    label = name
                    var result: EditorState?
                    chainBase = nil
                    got["command"] = .string(name)
                    got["applied"] = .bool(commands[name]!(state, { tr in result = try! (self.chainBase ?? state).apply(tr) }, nil))
                    if let result { got["doc"] = result.doc.toJSON(); got["selection"] = result.selection.toJSON() }
                } else if let key = op["key"]?.stringValue {
                    label = key
                    let view = OffsetView(state)
                    got["key"] = .string(key)
                    got["handled"] = .bool(plugin.props.handleKeyDown!(view, keyPress(key)))
                    got["doc"] = view.state.doc.toJSON(); got["selection"] = view.state.selection.toJSON()
                } else {
                    label = "paste"
                    let view = OffsetView(state)
                    got["slice"] = op["slice"]!
                    let slice = try Slice.fromJSON(schema, op["slice"]!)
                    got["handled"] = .bool(plugin.props.handlePaste!(view, slice))
                    got["doc"] = view.state.doc.toJSON(); got["selection"] = view.state.selection.toJSON()
                }
                if let cells = state.selection as? CellSelection {
                    got["content"] = cells.content().toJSON()
                    got["isRow"] = .bool(cells.isRowSelection)
                    got["isCol"] = .bool(cells.isColSelection)
                }
                m.equal(.object(got), op, "case \(ci) op \(oi) \(label) from \(op["sel"]!)")
            }
        }
        m.finish("tables", total: total)
    }
}

final class TableSafetyTests: XCTestCase {
    func cell(_ attrs: JSON = [:]) -> JSON {
        ["type": "table_cell", "attrs": attrs, "content": [["type": "paragraph"]]]
    }

    func testHostileSpansAreRejected() {
        let doc: JSON = ["type": "doc", "content": [["type": "table", "content": [
            ["type": "table_row", "content": [cell(["colspan": 1_000_000])]]]]]]
        XCTAssertThrowsError(try tableSchema.nodeFromJSON(doc, validate: true))
    }

    func testBadCellSelectionJSONThrows() throws {
        CellSelection.registerJSON()
        let doc = try tableSchema.nodeFromJSON(["type": "doc", "content": [["type": "table", "content": [
            ["type": "table_row", "content": [cell(), cell()]]]]]])
        // Position 1 is inside the table but before the row, not before a cell.
        XCTAssertThrowsError(try Selection.fromJSON(doc, ["type": "cell", "anchor": 1, "head": 1]))
        XCTAssertNoThrow(try Selection.fromJSON(doc, ["type": "cell", "anchor": 2, "head": 6]))
    }

    func testOversizedTableGetsEmptyMap() throws {
        // 1001 rows of one cell spanning 1000 columns: over a million slots.
        let row: JSON = ["type": "table_row", "content": [cell(["colspan": 1000])]]
        let doc = try tableSchema.nodeFromJSON(["type": "doc", "content": [["type": "table",
            "content": .array(Array(repeating: row, count: 1001))]]])
        let map = TableMap.get(doc.child(0))
        XCTAssertEqual(map.problems, [.tooLarge])
        XCTAssertEqual(map.width, 0)
        let state = try EditorState.create(.init(doc: doc, plugins: [Tables.editing()]))
        XCTAssertFalse(Tables.fixTables(state)?.docChanged ?? false, "oversized tables are left alone")
    }
}
