import ButtermilkCore
@testable import ButtermilkMarkdown
import XCTest

final class TableCommandTests: XCTestCase {
    let md = MarkdownConverter()
    let table = "| A | B |\n| :- | -: |\n| 1 | 2 |\n"

    /// Runs `command` with the cursor in the cell containing `text` and returns the Markdown.
    func run(_ command: Command, in text: String, markdown: String? = nil) throws -> String? {
        let doc = try md.parse(markdown ?? table)
        var pos: Int?
        doc.descendants { node, p, _, _ in
            if pos == nil, node.isText, node.text == text { pos = p }
            return pos == nil
        }
        let state = try EditorState.create(.init(doc: doc, selection: TextSelection(doc.resolve(try XCTUnwrap(pos)))))
        var result: EditorState?
        guard command(state, { result = try? state.apply($0) }, nil), let result else { return nil }
        return md.serialize(result.doc)
    }

    func cells(_ markdown: String?) -> [[String]] {
        (markdown ?? "").split(separator: "\n").map { line in
            line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    func testAddRowKeepsAlignment() throws {
        let out = try run(TableCommands.addRowAfter, in: "1")
        XCTAssertEqual(cells(out).count, 4)
        let doc = try md.parse(try XCTUnwrap(out))
        let tableNode = doc.child(0)
        XCTAssertEqual(tableNode.childCount, 3)
        XCTAssertEqual(tableNode.child(2).child(0).attrs["alignment"], "left")
        XCTAssertEqual(tableNode.child(2).child(1).attrs["alignment"], "right")
    }

    func testAddRowBeforeBodyRowKeepsAlignment() throws {
        let doc = try md.parse(try XCTUnwrap(try run(TableCommands.addRowBefore, in: "1")))
        XCTAssertEqual(doc.child(0).childCount, 3)
        XCTAssertEqual(doc.child(0).child(1).textContent, "")
        XCTAssertEqual(doc.child(0).child(1).child(1).attrs["alignment"], "right")
        XCTAssertEqual(doc.child(0).child(2).textContent, "12")
    }

    func testAddColumnKeepsHeaderRow() throws {
        let doc = try md.parse(try XCTUnwrap(try run(TableCommands.addColumnAfter, in: "A")))
        let header = doc.child(0).child(0)
        XCTAssertEqual(header.childCount, 3)
        XCTAssertEqual(header.child(1).type.name, "table_header")
        XCTAssertEqual(doc.child(0).child(1).child(1).type.name, "table_cell")
        XCTAssertEqual(header.child(2).attrs["alignment"], "right")
    }

    func testDeleteColumnAndRow() throws {
        let noB = try md.parse(try XCTUnwrap(try run(TableCommands.deleteColumn, in: "B")))
        XCTAssertEqual(noB.child(0).child(0).childCount, 1)
        XCTAssertEqual(noB.child(0).child(0).child(0).attrs["alignment"], "left")
        let noRow = try md.parse(try XCTUnwrap(try run(TableCommands.deleteRow, in: "2")))
        XCTAssertEqual(noRow.child(0).childCount, 1)
        XCTAssertEqual(noRow.child(0).textContent, "AB")
    }

    func testDeleteTable() throws {
        let out = try run(TableCommands.deleteTable, in: "1", markdown: "Before\n\n" + table)
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "Before")
    }
}
