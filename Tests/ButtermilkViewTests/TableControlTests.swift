#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

final class TableControlTests: XCTestCase {
    let schema = try! Schema(nodeList: BasicSchema.nodes + Tables.nodes(cellContent: "paragraph", tableGroup: "block"),
                             markList: BasicSchema.marks)

    func cell(_ type: String, _ text: String) -> JSON {
        ["type": .string(type), "content": [["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]]]
    }

    func makeView(cursor: Int) throws -> ButtermilkTextView {
        let json: JSON = ["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "x"]]],
            ["type": "table", "content": [
                ["type": "table_row", "content": [cell("table_header", "A"), cell("table_header", "B")]],
                ["type": "table_row", "content": [cell("table_cell", "1"), cell("table_cell", "2")]],
            ]],
        ]]
        let doc = try schema.nodeFromJSON(json)
        var config = EditorState.Config(doc: doc)
        config.selection = TextSelection(doc.resolve(cursor))
        return ButtermilkTextView(state: try EditorState.create(config))
    }

    func testControlsOnlyInTables() throws {
        XCTAssertEqual(try makeView(cursor: 1).core.tableControls, [])
        let view = try makeView(cursor: 7)
        XCTAssertEqual(view.core.tableControls, TableControl.allCases)
    }

    func testContextMenuRunsControls() throws {
        let view = try makeView(cursor: 7)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let titles = menu.items.map(\.title)
        for control in TableControl.allCases { XCTAssertTrue(titles.contains(control.title), control.title) }
        let item = try XCTUnwrap(menu.items.first { $0.title == TableControl.addRowAfter.title })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertEqual(view.state.doc.child(1).childCount, 3)
        XCTAssertTrue(view.core.run(.deleteColumn))
        XCTAssertEqual(view.state.doc.child(1).child(0).childCount, 1)
        XCTAssertTrue(view.core.run(.deleteTable))
        XCTAssertEqual(view.state.doc.childCount, 1)
        XCTAssertEqual(view.core.tableControls, [])
    }
}
#endif
