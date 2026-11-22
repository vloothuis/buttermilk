#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

final class DecorationViewTests: XCTestCase {
    let schema = BasicSchema.schema

    /// A plugin whose state is a decoration set, replaced by `setDecorations` meta and mapped otherwise.
    let key = PluginKey<DecorationSet>("decos")
    func plugin(_ initial: [Decoration]) -> Plugin {
        Plugin(key: key, state: StateField(
            initialize: { config, _ in DecorationSet.create(config.doc!, initial) },
            apply: { [key] tr, set, _, state in
                if let new = tr.getMeta(key) as? [Decoration] { return DecorationSet.create(state.doc, new) }
                return set.map(tr.mapping, tr.doc)
            }),
            props: { var p = EditorProps(); p.decorations = { [key] in key.getState($0) ?? .empty }; return p }())
    }

    func makeView(_ texts: [String], cursor: Int, _ decorations: [Decoration]) throws -> ButtermilkTextView {
        let doc = try schema.nodeFromJSON(["type": "doc", "content": .array(texts.map {
            $0.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": [["type": "text", "text": .string($0)]]]
        })])
        var config = EditorState.Config(doc: doc, plugins: [plugin(decorations)])
        config.selection = TextSelection.between(doc.resolve(cursor), doc.resolve(cursor))
        return ButtermilkTextView(state: try EditorState.create(config))
    }

    func color(_ view: ButtermilkTextView, at offset: Int) -> NSColor? {
        view.textStorage?.attribute(.backgroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    func testInlineDecorationStylesTextAndMapsOnTyping() throws {
        let view = try makeView(["hello"], cursor: 1, [.inline(2, 4, [.backgroundColor: NSColor.yellow])])
        XCTAssertEqual(view.string, "hello\n")
        XCTAssertNil(color(view, at: 0))
        XCTAssertEqual(color(view, at: 1), .yellow)
        XCTAssertEqual(color(view, at: 2), .yellow)
        XCTAssertNil(color(view, at: 3))
        view.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "abhello\n")
        XCTAssertNil(color(view, at: 2))
        XCTAssertEqual(color(view, at: 3), .yellow)
        XCTAssertEqual(color(view, at: 4), .yellow)
        XCTAssertNil(color(view, at: 5))
    }

    func testInlineDecorationSpansBlocks() throws {
        let view = try makeView(["ab", "cd"], cursor: 1, [.inline(2, 6, [.backgroundColor: NSColor.red])])
        XCTAssertEqual(view.string, "ab\ncd\n")
        XCTAssertEqual([0, 1, 3, 4].map { color(view, at: $0) }, [nil, .red, .red, nil])
    }

    func testNodeDecorationStylesWholeNode() throws {
        let view = try makeView(["one", "two"], cursor: 1, [.node(5, 10, [.backgroundColor: NSColor.blue])])
        XCTAssertNil(color(view, at: 2))
        XCTAssertEqual([4, 5, 6].map { color(view, at: $0) }, [.blue, .blue, .blue])
    }

    func testWidgetIsShownButNotInTheDocument() throws {
        let ghost = Decoration.widget(4, " world", [.foregroundColor: NSColor.gray], side: 1)
        let view = try makeView(["abc"], cursor: 4, [ghost])
        XCTAssertEqual(view.string, "abc world\n")
        XCTAssertEqual(view.state.doc.textContent, "abc")
        let storage = view.textStorage!
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .gray)
        XCTAssertEqual(storage.attribute(.buttermilkWidget, at: 4, effectiveRange: nil) as? Bool, true)
        XCTAssertNotNil(storage.attribute(.font, at: 4, effectiveRange: nil))
        let map = view.core.rendered.map
        XCTAssertEqual(map.offset(for: 4), 3)
        XCTAssertEqual(map.position(for: 9), 4)
        XCTAssertFalse(map.isInText(6))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        // Typing before the widget moves it along.
        view.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.state.doc.textContent, "abcd")
        XCTAssertEqual(view.string, "abcd world\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testWidgetsInMiddleSplitTheMap() throws {
        let view = try makeView(["abcd"], cursor: 1, [.widget(2, "[1]"), .widget(4, "[2]")])
        XCTAssertEqual(view.string, "a[1]bc[2]d\n")
        let map = view.core.rendered.map
        XCTAssertEqual([1, 2, 3, 4, 5].map { map.offset(for: $0) }, [0, 1, 5, 6, 10])
        XCTAssertEqual(map.position(for: 4), 2)
        XCTAssertEqual(map.position(for: 10), 5)
        view.setSelectedRange(NSRange(location: 4, length: 2))
        XCTAssertEqual(view.state.selection.from, 2)
        XCTAssertEqual(view.state.selection.to, 4)
    }

    func testChangingDecorationsRerendersOnlyAffectedBlocks() throws {
        let view = try makeView(["one", "two", "three"], cursor: 1, [])
        let before = view.core.rendered.blocks.map(\.text)
        let tr = view.state.tr.setMeta(self.key, [Decoration.inline(6, 8, [.backgroundColor: NSColor.green])] as [Decoration])
        view.core.dispatch(tr)
        let after = view.core.rendered.blocks.map(\.text)
        XCTAssertTrue(before[0] === after[0])
        XCTAssertFalse(before[1] === after[1])
        XCTAssertTrue(before[2] === after[2])
        XCTAssertEqual(view.string, "one\ntwo\nthree\n")
        XCTAssertEqual(color(view, at: 4), .green)
        view.core.dispatch(view.state.tr.setMeta(self.key, [Decoration]()))
        XCTAssertNil(color(view, at: 4))
        XCTAssertEqual(view.string, view.core.rendered.text.string)
    }
}
#endif
