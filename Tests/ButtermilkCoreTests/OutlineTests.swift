import Foundation
import XCTest
@testable import ButtermilkCore

final class OutlineTests: XCTestCase {
    func h(_ level: Int, _ text: String) -> JSON {
        ["type": "heading", "attrs": ["level": .number(Double(level))], "content": [["type": "text", "text": .string(text)]]]
    }
    func p(_ text: String) -> JSON { ["type": "paragraph", "content": [["type": "text", "text": .string(text)]]] }
    func doc(_ blocks: JSON...) throws -> Node { try testSchema.nodeFromJSON(["type": "doc", "content": .array(blocks)]) }

    func run(_ state: EditorState, _ command: Command) -> EditorState? {
        var out: EditorState?
        _ = command(state, { out = try? state.apply($0) }, nil)
        return out
    }

    // Positions: intro 0-7, A 7-10, a 10-13, B 13-16, b 16-19, C 19-22, D 22-25 (end 25).
    func sample() throws -> Node {
        try doc(p("intro"), h(1, "A"), p("a"), h(2, "B"), p("b"), h(3, "C"), h(1, "D"))
    }

    func testHeadings() throws {
        let list = Outline.headings(try sample())
        XCTAssertEqual(list.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(list.map(\.level), [1, 2, 3, 1])
        XCTAssertEqual(list.map(\.pos), [7, 13, 19, 22])
        XCTAssertEqual(list.map(\.index), [1, 3, 5, 6])
    }

    func testTree() throws {
        let tree = Outline.tree(try doc(h(2, "x"), h(1, "A"), h(3, "B"), h(2, "C"), h(1, "D")))
        XCTAssertEqual(tree.map(\.heading.text), ["x", "A", "D"])
        XCTAssertEqual(tree[1].children.map(\.heading.text), ["B", "C"])
        XCTAssertTrue(tree[1].children[0].children.isEmpty)
    }

    func testSectionAtPosition() throws {
        let d = try sample()
        XCTAssertNil(Outline.section(d, at: 3))
        let a = try XCTUnwrap(Outline.section(d, at: 11))
        XCTAssertEqual([a.heading.text, "\(a.from)", "\(a.to)"], ["A", "7", "22"])
        XCTAssertTrue(a.ancestors.isEmpty)
        let c = try XCTUnwrap(Outline.section(d, at: 20))
        XCTAssertEqual([c.from, c.to], [19, 22])
        XCTAssertEqual(c.ancestors.map(\.text), ["A", "B"])
        let dd = try XCTUnwrap(Outline.section(d, at: 23))
        XCTAssertEqual(dd.to, 25)
        XCTAssertEqual(Outline.section(d, at: 13)?.heading.text, "B")
    }

    func testNestedHeadingsAndEmpty() throws {
        let quoted = try doc(p("x"), ["type": "blockquote", "content": [h(1, "Q")]])
        XCTAssertTrue(Outline.headings(quoted).isEmpty)
        XCTAssertNil(Outline.section(quoted, at: 4))
        XCTAssertTrue(Outline.tree(try doc(p("x"))).isEmpty)
    }

    func testCommands() throws {
        let d = try sample()
        let state = try EditorState.create(.init(doc: d, selection: TextSelection.create(d, 17)))
        let selected = try XCTUnwrap(run(state, Outline.selectSection()))
        XCTAssertEqual([selected.selection.from, selected.selection.to], [14, 21])
        XCTAssertEqual(run(state, Outline.moveToHeading())?.selection.head, 20)
        XCTAssertEqual(run(state, Outline.moveToHeading(forward: false))?.selection.head, 14)
        let start = try EditorState.create(.init(doc: d, selection: TextSelection.create(d, 2)))
        XCTAssertFalse(Outline.selectSection()(start, nil, nil))
        XCTAssertFalse(Outline.moveToHeading(forward: false)(start, nil, nil))
    }
}
