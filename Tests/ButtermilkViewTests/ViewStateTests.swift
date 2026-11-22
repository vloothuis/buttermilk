#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

final class ViewStateTests: XCTestCase {
    let schema = BasicSchema.schema

    func makeDoc(_ n: Int, schema: Schema? = nil) throws -> Node {
        let blocks: [JSON] = (0..<n).map { ["type": "paragraph", "content": [["type": "text", "text": .string("Paragraph \($0) with some text.")]]] }
        return try (schema ?? self.schema).nodeFromJSON(["type": "doc", "content": .array(blocks)])
    }

    func makeView(_ doc: Node, width: CGFloat = 480) throws -> ButtermilkTextView {
        ButtermilkTextView(state: try EditorState.create(.init(doc: doc)), frame: NSRect(x: 0, y: 0, width: width, height: 320))
    }

    func embed(_ view: ButtermilkTextView, width: CGFloat = 480) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        scroll.documentView = view
        view.sizeToFit()
        return scroll
    }

    func scrollTo(_ scroll: NSScrollView, _ y: CGFloat) {
        let view = scroll.documentView as! ButtermilkTextView
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    }

    func testCodableRoundTrip() throws {
        let state = EditorViewState(selection: ["type": "text", "anchor": 3, "head": 5], scrollAnchor: ScrollAnchor(pos: 40, offset: 2.5))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EditorViewState.self, from: data), state)
    }

    func testSelectionRoundTripsAndClamps() throws {
        let view = try makeView(try makeDoc(3))
        view.core.dispatch(view.state.tr.setSelection(TextSelection.between(view.state.doc.resolve(3), view.state.doc.resolve(8))))
        let saved = view.saveViewState()
        let other = try makeView(try makeDoc(3))
        other.restoreViewState(saved)
        XCTAssertEqual(other.state.selection.anchor, 3)
        XCTAssertEqual(other.state.selection.head, 8)

        let small = try makeView(try makeDoc(1))
        small.restoreViewState(EditorViewState(selection: ["type": "text", "anchor": 3, "head": 500]))
        XCTAssertTrue(small.state.selection is TextSelection)
        XCTAssertEqual(small.state.selection.anchor, 3)
        XCTAssertLessThanOrEqual(small.state.selection.head, small.state.doc.content.size)
        XCTAssertEqual(small.selectedRange().location, 2)
    }

    func testNodeAndCellSelections() throws {
        let view = try makeView(try schema.nodeFromJSON(["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "a"]]], ["type": "horizontal_rule"]]]))
        view.restoreViewState(EditorViewState(selection: NodeSelection.create(view.state.doc, 3).toJSON()))
        XCTAssertTrue(view.state.selection is NodeSelection)
        XCTAssertEqual(view.state.selection.from, 3)

        // A node selection that no longer points at a node falls back to a text selection.
        view.restoreViewState(EditorViewState(selection: ["type": "node", "anchor": 99]))
        XCTAssertTrue(view.state.selection is TextSelection)

        CellSelection.registerJSON()
        let tableSchema = try Schema(nodeList: BasicSchema.nodes + Tables.nodes(cellContent: "paragraph", tableGroup: "block"), markList: BasicSchema.marks)
        func cell(_ t: String) -> JSON { ["type": "table_cell", "content": [["type": "paragraph", "content": [["type": "text", "text": .string(t)]]]]] }
        let doc = try tableSchema.nodeFromJSON(["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "x"]]],
            ["type": "table", "content": [["type": "table_row", "content": [cell("A"), cell("B")]],
                                          ["type": "table_row", "content": [cell("1"), cell("2")]]]]]])
        let table = try makeView(doc)
        let json = try CellSelection.create(doc, 5, 22).toJSON()
        table.restoreViewState(EditorViewState(selection: json))
        XCTAssertEqual(table.saveViewState().selection, json)
    }

    func testScrollAnchorSurvivesWidthChange() throws {
        let view = try makeView(try makeDoc(400))
        let scroll = embed(view)
        scrollTo(scroll, 3000)
        let saved = view.saveViewState()
        let anchor = try XCTUnwrap(saved.scrollAnchor)
        XCTAssertGreaterThan(anchor.pos, 0)
        view.scroll(to: ScrollAnchor(pos: 0, offset: 0))
        XCTAssertEqual(scroll.contentView.bounds.minY, view.textContainerOrigin.y, accuracy: 0.5)
        view.scroll(to: anchor)
        XCTAssertEqual(scroll.contentView.bounds.minY, 3000, accuracy: 0.5)

        // A narrower view wraps lines, so the same anchor sits at a different pixel offset.
        let narrow = try makeView(try makeDoc(400), width: 160)
        _ = embed(narrow, width: 160)
        narrow.restoreViewState(saved)
        let restored = try XCTUnwrap(narrow.scrollAnchor())
        XCTAssertEqual(restored.pos, anchor.pos)
        XCTAssertEqual(restored.offset, anchor.offset, accuracy: 0.5)
    }

    func testRestoreBeforeLayoutAppliesWhenEmbedded() throws {
        let source = try makeView(try makeDoc(400))
        scrollTo(embed(source), 2000)
        let saved = source.saveViewState()

        let view = try makeView(try makeDoc(400))
        view.restoreViewState(saved)
        XCTAssertNil(view.scrollAnchor())
        XCTAssertEqual(view.saveViewState().scrollAnchor, saved.scrollAnchor)
        let scroll = embed(view)
        XCTAssertNotNil(view.saveViewState().scrollAnchor)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = scroll
        XCTAssertEqual(scroll.contentView.bounds.minY, 2000, accuracy: 0.5)
        XCTAssertEqual(view.saveViewState().scrollAnchor, saved.scrollAnchor)
    }

    func testScrollAnchorClampsToDocument() throws {
        let view = try makeView(try makeDoc(3))
        let scroll = embed(view)
        view.restoreViewState(EditorViewState(scrollAnchor: ScrollAnchor(pos: 99_999, offset: 99_999)))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    }
}
#endif
