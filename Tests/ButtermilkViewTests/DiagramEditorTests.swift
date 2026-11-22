#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

/// Marks `graph` as a keyword.
struct GraphHighlighter: SyntaxHighlighter {
    func tokens(in code: String, language: String) -> [SyntaxToken]? {
        let r = (code as NSString).range(of: "graph")
        return r.location == NSNotFound ? [] : [SyntaxToken(r, .keyword)]
    }
}

/// Reports every `??` as an error.
struct QuestionLinter: DiagramLinter {
    func diagnostics(in source: String, language: String) -> [DiagramDiagnostic] {
        var out: [DiagramDiagnostic] = [], search = NSRange(location: 0, length: (source as NSString).length)
        while case let r = (source as NSString).range(of: "??", range: search), r.location != NSNotFound {
            out.append(DiagramDiagnostic(r, .error, "unknown token"))
            search = NSRange(location: NSMaxRange(r), length: search.length - (NSMaxRange(r) - search.location))
        }
        return out
    }
}

struct KeywordCompleter: DiagramCompleter {
    func completions(for prefix: String, in source: String, at offset: Int, language: String) -> [String] {
        ["graph", "subgraph", "gantt"].filter { $0.hasPrefix(prefix) && $0 != prefix }
    }
}

final class DiagramEditorTests: XCTestCase {
    static let schema: Schema = {
        var nodes = BasicSchema.nodes
        let i = nodes.firstIndex { $0.0 == "code_block" }!
        nodes[i].1.attrs["language"] = AttributeSpec(default: "", validateType: "string")
        return try! Schema(nodeList: nodes, markList: BasicSchema.marks)
    }()

    func para(_ s: String) -> JSON { ["type": "paragraph", "content": [["type": "text", "text": .string(s)]]] }
    func code(_ s: String, _ language: String) -> JSON {
        ["type": "code_block", "attrs": ["language": .string(language)], "content": [["type": "text", "text": .string(s)]]]
    }

    func makeView(_ content: [JSON], cursor: Int = 1) throws -> ButtermilkTextView {
        let doc = try Self.schema.nodeFromJSON(["type": "doc", "content": .array(content)])
        var config = EditorState.Config(doc: doc)
        config.selection = TextSelection.create(doc, cursor)
        let view = ButtermilkTextView(state: try EditorState.create(config))
        DiagramBlocks(completer: KeywordCompleter(), linter: QuestionLinter(), highlighter: GraphHighlighter()).install(on: view.core)
        return view
    }

    var editor: (ButtermilkTextView) -> DiagramEditor = { $0.nodeViews.compactMap { $0 as? DiagramEditor }[0] }

    func testRendersDiagramBlocksAsEditors() throws {
        let view = try makeView([para("ab"), code("graph TD", "mermaid"), code("let x", "swift")])
        XCTAssertEqual(view.nodeViews.count, 1)
        let e = editor(view)
        XCTAssertEqual(e.source, "graph TD")
        XCTAssertEqual(e.language, "mermaid")
        XCTAssertEqual(e.getPos(), 4)
        XCTAssertTrue(e.textView.superview === view)
        // The diagram block is one attachment; the Swift block keeps its text.
        XCTAssertEqual(view.string, "ab\n\u{FFFC}\nlet x\n")
        let color = e.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, view.core.renderer.theme.syntaxColors[.keyword])
        XCTAssertGreaterThan(e.size.height, 0)
    }

    func testEditsBecomeTransactions() throws {
        let view = try makeView([para("ab"), code("graph", "mermaid")])
        let e = editor(view)
        e.textView.setSelectedRange(NSRange(location: 5, length: 0))
        e.textView.insertText(" LR\nA-->B", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.state.doc.child(1).textContent, "graph LR\nA-->B")
        XCTAssertTrue(editor(view) === e)
        XCTAssertEqual(e.textView.selectedRange().location, 14)
        // The block grew, and the attachment with it.
        let attachment = view.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) as? NodeViewAttachment
        XCTAssertEqual(attachment?.bounds.size, e.size)

        e.textView.selectAll(nil)
        e.textView.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.textView.delete(nil)
        XCTAssertEqual(view.state.doc.child(1).textContent, "")
        XCTAssertEqual(view.state.doc.child(1).type.name, "code_block")
    }

    func testDocumentChangesUpdateTheEditor() throws {
        let view = try makeView([para("ab"), code("graph", "mermaid")])
        let e = editor(view)
        view.dispatch(try view.state.tr.insertText("sub", 5))
        XCTAssertTrue(editor(view) === e)
        XCTAssertEqual(e.source, "subgraph")
        // A language that is not a diagram language turns it back into a code block.
        view.dispatch(try view.state.tr.setNodeAttribute(4, "language", "swift"))
        XCTAssertTrue(view.nodeViews.isEmpty)
        XCTAssertNil(e.textView.superview)
        XCTAssertEqual(view.string, "ab\nsubgraph\n")
    }

    func testShowsLintDiagnostics() throws {
        let view = try makeView([code("A ?? B", "mermaid")])
        let e = editor(view)
        XCTAssertEqual(e.diagnostics, [DiagramDiagnostic(NSRange(location: 2, length: 2), .error, "unknown token")])
        let storage = e.textView.textStorage!
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: 2, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.underlineColor, at: 3, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertEqual(storage.attribute(.buttermilkDiagnostic, at: 2, effectiveRange: nil) as? String, "unknown token")
        XCTAssertNil(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        e.textView.setSelectedRange(NSRange(location: 2, length: 2))
        e.textView.insertText("-->", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(e.diagnostics, [])
        XCTAssertNil(storage.attribute(.underlineStyle, at: 2, effectiveRange: nil))
    }

    func testCompletions() throws {
        let view = try makeView([code("A\nsub", "mermaid")])
        let e = editor(view)
        e.textView.setSelectedRange(NSRange(location: 5, length: 0))
        let found = e.completions()
        XCTAssertEqual(found.range, NSRange(location: 2, length: 3))
        XCTAssertEqual(found.words, ["subgraph"])
        XCTAssertEqual(e.textView.rangeForUserCompletion, NSRange(location: 2, length: 3))
        var index = 5
        XCTAssertEqual(e.textView(e.textView, completions: [], forPartialWordRange: found.range, indexOfSelectedItem: &index), ["subgraph"])
        XCTAssertEqual(index, 0)
    }

    func testArrowKeysMoveInAndOut() throws {
        let view = try makeView([para("ab"), code("graph\nA", "mermaid"), para("cd")], cursor: 3)
        let e = editor(view)
        XCTAssertTrue(view.core.handleKey(KeyPress("ArrowDown")))
        XCTAssertEqual((view.state.selection as? NodeSelection)?.from, 4)
        XCTAssertEqual(e.textView.selectedRange(), NSRange(location: 0, length: 0))
        // Up on the first line goes back above the block.
        XCTAssertTrue(e.textView(e.textView, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(view.state.selection.head, 3)
        XCTAssertTrue(view.state.selection is TextSelection)

        // From the paragraph below, Up enters at the end; Down on the last line leaves again.
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 14)))
        XCTAssertTrue(view.core.handleKey(KeyPress("ArrowLeft")))
        XCTAssertEqual(e.textView.selectedRange(), NSRange(location: 7, length: 0))
        e.textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertFalse(e.textView(e.textView, doCommandBy: #selector(NSResponder.moveDown(_:))))
        e.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(e.textView(e.textView, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertEqual(view.state.selection.head, 14)
    }

    func testArrowKeysIgnorePlainNodeViews() throws {
        let view = try makeView([para("ab"), code("let x", "swift")], cursor: 3)
        XCTAssertFalse(view.core.handleKey(KeyPress("ArrowDown")))
    }
}
#endif
