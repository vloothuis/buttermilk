#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

final class TextViewTests: XCTestCase {
    let schema = BasicSchema.schema

    func makeView(_ json: JSON, cursor: Int? = nil, plugins: [Plugin] = []) throws -> ButtermilkTextView {
        let doc = try schema.nodeFromJSON(json)
        var config = EditorState.Config(doc: doc, plugins: plugins)
        if let cursor { config.selection = TextSelection.between(doc.resolve(cursor), doc.resolve(cursor)) }
        return ButtermilkTextView(state: try EditorState.create(config))
    }

    func para(_ text: String) -> JSON {
        text.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]
    }

    func doc(_ blocks: JSON...) -> JSON { ["type": "doc", "content": .array(blocks)] }

    func testRendersTextAndMapsPositions() throws {
        let view = try makeView(doc(para("Hello"), ["type": "heading", "attrs": ["level": 1], "content": [["type": "text", "text": "Title"]]]))
        XCTAssertEqual(view.string, "Hello\nTitle\n")
        let map = view.core.rendered.map
        XCTAssertEqual(map.offset(for: 1), 0)
        XCTAssertEqual(map.offset(for: 8), 6)
        XCTAssertEqual(map.position(for: 6), 8)
        XCTAssertEqual(map.position(for: 5), 6)
    }

    func testTypingGoesThroughTheState() throws {
        let view = try makeView(doc(para("ac")), cursor: 2)
        view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.state.doc.textContent, "abc")
        XCTAssertEqual(view.string, "abc\n")
        XCTAssertEqual(view.state.selection.from, 3)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testEnterAndBackspace() throws {
        let view = try makeView(doc(para("ab")), cursor: 2)
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(view.state.doc.childCount, 2)
        XCTAssertEqual(view.string, "a\nb\n")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.state.doc.childCount, 1)
        XCTAssertEqual(view.string, "ab\n")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.state.doc.textContent, "b")
    }

    func testDeletesWholeGraphemes() throws {
        let view = try makeView(doc(para("a👍🏽")), cursor: 1 + ("a👍🏽" as NSString).length)
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.state.doc.textContent, "a")
    }

    func testSelectionFromTextKit() throws {
        let view = try makeView(doc(para("one"), para("two")))
        view.setSelectedRange(NSRange(location: 1, length: 5))
        XCTAssertEqual(view.state.selection.from, 2)
        XCTAssertEqual(view.state.selection.to, 8)
    }

    func testCompositionCommitsOnce() throws {
        let view = try makeView(doc(para("")), cursor: 1)
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.composing)
        XCTAssertEqual(view.state.doc.textContent, "")
        view.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.composing)
        XCTAssertEqual(view.state.doc.textContent, "か")
        XCTAssertEqual(view.string, "か\n")
    }

    func testKeymapPluginsRunFirst() throws {
        var called = false
        let plugin = Keymap.plugin(["Mod-b": { _, _, _ in called = true; return true }])
        let view = try makeView(doc(para("x")), cursor: 1, plugins: [plugin])
        XCTAssertTrue(view.core.handleKey(KeyPress("b", modifiers: .command)))
        XCTAssertTrue(called)
    }

    func testUndoThroughHistory() throws {
        let view = try makeView(doc(para("")), cursor: 1,
                                plugins: [History.plugin(), Keymap.plugin(["Mod-z": History.undo])])
        view.insertText("hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "hi\n")
        XCTAssertTrue(view.core.handleKey(KeyPress("z", modifiers: .command)))
        XCTAssertEqual(view.string, "\n")
    }

    func testCopyAndPasteKeepStructure() throws {
        let view = try makeView(doc(para("one"), para("two")))
        view.core.dispatch(view.state.tr.setSelection(TextSelection.between(view.state.doc.resolve(1), view.state.doc.resolve(9))))
        let pb = NSPasteboard(name: .init("buttermilk-test"))
        pb.clearContents()
        XCTAssertTrue(view.writeSelection(to: pb, types: view.writablePasteboardTypes))
        XCTAssertEqual(pb.string(forType: .string), "one\n\ntwo")
        view.core.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)))
        XCTAssertTrue(view.readSelection(from: pb, type: .string))
        XCTAssertEqual(view.state.doc.childCount, 3)
        XCTAssertEqual(view.string, "one\ntwoone\ntwo\n")
    }

    func testRendersHorizontalRuleAsNodeSelectableAtom() throws {
        let view = try makeView(doc(para("a"), ["type": "horizontal_rule"], para("b")))
        XCTAssertEqual(view.string, "a\n\u{FFFC}\nb\n")
        view.setSelectedRange(NSRange(location: 2, length: 1))
        XCTAssertTrue(view.state.selection is NodeSelection)
        XCTAssertEqual(view.state.selection.from, 3)
    }

    func testDrawsToBitmap() throws {
        let view = try makeView(doc(para("Bitmap"), ["type": "code_block", "content": [["type": "text", "text": "let x = 1"]]]))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }
}
#endif

#if canImport(AppKit)
final class RenderSnapshotTests: XCTestCase {
    func testRichDocumentRenders() throws {
        let nodes = ListSchema.addListNodes(BasicSchema.nodes, itemContent: "paragraph block*", listGroup: "block")
            + Tables.nodes(cellContent: "block+", tableGroup: "block")
        let schema = try Schema(nodeList: nodes, markList: BasicSchema.marks)
        func t(_ s: String, _ marks: [JSON] = []) -> JSON { marks.isEmpty ? ["type": "text", "text": .string(s)] : ["type": "text", "text": .string(s), "marks": .array(marks)] }
        func p(_ c: JSON...) -> JSON { ["type": "paragraph", "content": .array(c)] }
        func cell(_ s: String, header: Bool = false, colspan: Int = 1) -> JSON {
            ["type": header ? "table_header" : "table_cell", "attrs": ["colspan": colspan.json], "content": [p(t(s))]]
        }
        let json: JSON = ["type": "doc", "content": [
            ["type": "heading", "attrs": ["level": 1], "content": [t("Buttermilk")]],
            p(t("A "), t("native", [["type": "strong"]]), t(" editor with "), t("marks", [["type": "em"]]), t(", "),
              t("code", [["type": "code"]]), t(" and "), t("links", [["type": "link", "attrs": ["href": "https://milkdown.dev"]]]), t(".")),
            ["type": "bullet_list", "content": [
                ["type": "list_item", "content": [p(t("First item"))]],
                ["type": "list_item", "content": [p(t("Second item")), ["type": "ordered_list", "content": [
                    ["type": "list_item", "content": [p(t("Nested one"))]],
                    ["type": "list_item", "content": [p(t("Nested two"))]]]]]]]],
            ["type": "blockquote", "content": [p(t("A quote spanning a line of text."))]],
            ["type": "code_block", "content": [t("let editor = ButtermilkTextView(state: state)")]],
            ["type": "horizontal_rule"],
            ["type": "table", "content": [
                ["type": "table_row", "content": [cell("Name", header: true), cell("Value", header: true)]],
                ["type": "table_row", "content": [cell("Width"), cell("2")]],
                ["type": "table_row", "content": [cell("Spanning both", colspan: 2)]]]],
            p(t("End.")),
        ]]
        let doc = try schema.nodeFromJSON(json)
        let view = ButtermilkTextView(state: try EditorState.create(.init(doc: doc)),
                                      frame: NSRect(x: 0, y: 0, width: 520, height: 640))
        view.appearance = NSAppearance(named: .aqua)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        // Every document position inside text must round-trip through the map.
        let map = view.core.rendered.map
        for seg in map.segments {
            for pos in seg.pos...(seg.pos + seg.length) { XCTAssertEqual(map.position(for: map.offset(for: pos)), pos) }
        }
        if let path = ProcessInfo.processInfo.environment["BUTTERMILK_SNAPSHOT"] {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

#if canImport(AppKit)
final class RenderSafetyTests: XCTestCase {
    func testUnsafeLinksAndImagesAreInert() throws {
        let schema = BasicSchema.schema
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [
            ["type": "text", "text": "a", "marks": [["type": "link", "attrs": ["href": "javascript:alert(1)"]]]],
            ["type": "text", "text": "b", "marks": [["type": "link", "attrs": ["href": "https://example.com"]]]],
            ["type": "image", "attrs": ["src": "/etc/hosts"]]]]]])
        var asked: [String] = []
        var renderer = DocumentRenderer()
        let text = renderer.render(doc).text
        XCTAssertNil(text.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.link, at: 1, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        renderer.imageLoader = { asked.append($0); return nil }
        _ = renderer.render(doc)
        XCTAssertEqual(asked, ["/etc/hosts"])
    }
}
#endif

#if canImport(AppKit)
final class IncrementalRenderTests: XCTestCase {
    let schema = BasicSchema.schema

    func bigDoc(_ n: Int) throws -> Node {
        let blocks: [JSON] = (0..<n).map { i in
            i % 7 == 3 ? ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": .string("Heading \(i)")]]]
                : ["type": "paragraph", "content": [["type": "text", "text": .string("Paragraph \(i) with some text.")]]]
        }
        return try schema.nodeFromJSON(["type": "doc", "content": .array(blocks)])
    }

    func assertInSync(_ view: ButtermilkTextView, file: StaticString = #filePath, line: UInt = #line) {
        let full = view.core.renderer.render(view.state.doc)
        XCTAssertEqual(view.string, full.text.string, file: file, line: line)
        XCTAssertEqual(view.core.rendered.map.segments.map(\.pos), full.map.segments.map(\.pos), file: file, line: line)
        XCTAssertEqual(view.core.rendered.map.segments.map(\.offset), full.map.segments.map(\.offset), file: file, line: line)
    }

    func testIncrementalEditsMatchFullRender() throws {
        let view = ButtermilkTextView(state: try EditorState.create(.init(doc: try bigDoc(40))))
        var rng = SystemRandomNumberGenerator()
        for step in 0..<200 {
            let size = view.state.doc.content.size
            let pos = Int.random(in: 0...size, using: &rng)
            view.core.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))))
            switch step % 4 {
            case 0: view.insertText("x\(step)", replacementRange: NSRange(location: NSNotFound, length: 0))
            case 1: view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case 2: view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            default:
                let a = Int.random(in: 0...size, using: &rng), b = Int.random(in: 0...size, using: &rng)
                let d = view.state.doc
                view.core.dispatch(view.state.tr.setSelection(TextSelection.between(d.resolve(min(a, b)), d.resolve(max(a, b)))))
                view.core.deleteSelection()
            }
            assertInSync(view)
        }
    }

    func testTypingInLargeDocumentIsFast() throws {
        let view = ButtermilkTextView(state: try EditorState.create(.init(doc: try bigDoc(20_000))))
        view.core.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(view.state.doc.content.size / 2))))
        let start = Date()
        for _ in 0..<100 { view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let perKey = Date().timeIntervalSince(start) / 100
        #if DEBUG
        let limit = 0.04
        #else
        let limit = 0.008
        #endif
        XCTAssertLessThan(perKey, limit, "typing took \(Int(perKey * 1000)) ms per key")
        print("typing: \(String(format: "%.2f", perKey * 1000)) ms per key")
    }
}
#endif

#if canImport(AppKit)
final class ProfileTests: XCTestCase {
    func testProfile() throws {
        guard ProcessInfo.processInfo.environment["BM_PROFILE"] != nil else { return }
        let t = IncrementalRenderTests()
        let doc = try t.bigDoc(20_000)
        var state = try EditorState.create(.init(doc: doc))
        state = try state.apply(state.tr.setSelection(TextSelection.near(doc.resolve(doc.content.size / 2))))
        let r = DocumentRenderer()
        var rendered = r.render(doc)
        func time(_ name: String, _ f: () throws -> Void) rethrows { let s = Date(); for _ in 0..<20 { try f() }; print("PROF", name, String(format: "%.2f ms", Date().timeIntervalSince(s) * 50)) }
        var next = state
        try time("apply") { next = try state.apply(state.tr.insertText("a")) }
        time("update") { var copy = rendered; _ = r.update(&copy, to: next.doc) }
        time("mapinit") { _ = RenderedDocument(blocks: rendered.blocks) }
        let view = ButtermilkTextView(state: state)
        var rd = rendered
        time("update-inplace") { _ = r.update(&rd, to: next.doc); _ = r.update(&rd, to: state.doc) }
        let storage = view.textStorage!
        time("storage-edit") { storage.replaceCharacters(in: NSRange(location: 1000, length: 0), with: "a") }
        time("select") { view.setSelectedRange(NSRange(location: 1000, length: 0)) }
        time("scroll") { view.scrollRangeToVisible(NSRange(location: 400000, length: 0)) }
        try time("dispatch") { view.core.apply(try view.state.tr.insertText("a")) }
    }
}
#endif
