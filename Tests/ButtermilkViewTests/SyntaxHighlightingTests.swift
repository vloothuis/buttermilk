import ButtermilkCore
@testable import ButtermilkView
import XCTest

/// Highlights every code block whole as a string and counts its calls.
final class CountingHighlighter: SyntaxHighlighter {
    var calls: [String] = []
    func tokens(in code: String, language: String) -> [SyntaxToken]? {
        calls.append(code)
        return [SyntaxToken(NSRange(location: 0, length: (code as NSString).length), .string)]
    }
}

final class SyntaxHighlightingTests: XCTestCase {
    let schema: Schema = {
        var nodes = BasicSchema.nodes.filter { $0.0 != "code_block" }
        nodes.append(("code_block", NodeSpec(content: "text*", marks: "", group: "block",
                                             attrs: ["language": AttributeSpec(default: "", validateType: "string")],
                                             code: true, defining: true)))
        return try! Schema(nodeList: nodes, markList: BasicSchema.marks)
    }()

    func doc(_ code: String, language: String, paragraph: String = "hi") throws -> Node {
        try schema.nodeFromJSON(["type": "doc", "content": [
            ["type": "paragraph", "content": [["type": "text", "text": .string(paragraph)]]],
            ["type": "code_block", "attrs": ["language": .string(language)],
             "content": [["type": "text", "text": .string(code)]]],
        ]])
    }

    func kinds(_ code: String, _ language: String) -> [(String, SyntaxTokenKind)] {
        let ns = code as NSString
        return (BuiltinHighlighter().tokens(in: code, language: language) ?? []).map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testBuiltinLexesSwift() {
        let got = kinds("let x = 42 // hi\nfunc f() -> String { \"a\\\"b\" }", "swift")
        XCTAssertEqual(got.map(\.0), ["let", "42", "// hi", "func", "String", "\"a\\\"b\""])
        XCTAssertEqual(got.map(\.1), [.keyword, .number, .comment, .keyword, .type, .string])
    }

    func testBuiltinLexesPythonAndBlockComments() {
        XCTAssertEqual(kinds("def f():\n    '''doc\nmore'''  # c", "python").map(\.0), ["def", "'''doc\nmore'''", "# c"])
        XCTAssertEqual(kinds("a /* x\ny */ b", "js").map(\.1), [.comment])
        XCTAssertEqual(kinds("{\"a\": true, \"b\": 1.5}", "json").map(\.1), [.string, .keyword, .string, .number])
        XCTAssertEqual(kinds("x1 = 2", "go").map(\.0), ["2"])
    }

    func testBuiltinUsesUTF16RangesAndIgnoresUnknownLanguages() {
        XCTAssertEqual(kinds("\"é😀\" let", "swift").map(\.0), ["\"é😀\"", "let"])
        XCTAssertNil(BuiltinHighlighter().tokens(in: "let x", language: "cobol"))
        XCTAssertNil(BuiltinHighlighter().tokens(in: "let x", language: ""))
    }

    func testRendererColorsCodeBlockTokens() throws {
        let renderer = DocumentRenderer()
        let text = renderer.render(try doc("let x", language: "Swift")).text
        // "hi\n" then "let x\n".
        let color = text.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? PlatformColor
        XCTAssertEqual(color, renderer.theme.syntaxColors[.keyword])
        XCTAssertEqual(text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? PlatformColor, renderer.theme.textColor)

        var off = renderer
        off.highlighter = nil
        let plain = off.render(try doc("let x", language: "swift")).text
        XCTAssertEqual(plain.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? PlatformColor, renderer.theme.textColor)
    }

    func testHostHighlighterPerLanguageWithFallback() throws {
        let custom = CountingHighlighter()
        var renderer = DocumentRenderer()
        renderer.highlighter = LanguageHighlighters(["Mine": custom])
        let strings = renderer.theme.syntaxColors[.string]
        var text = renderer.render(try doc("abc", language: "mine")).text
        XCTAssertEqual(custom.calls, ["abc"])
        XCTAssertEqual(text.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? PlatformColor, strings)
        text = renderer.render(try doc("let", language: "swift")).text
        XCTAssertEqual(custom.calls.count, 1)
        XCTAssertEqual(text.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? PlatformColor,
                       renderer.theme.syntaxColors[.keyword])
    }

    func testOnlyChangedCodeBlocksAreHighlightedAgain() throws {
        let custom = CountingHighlighter()
        var renderer = DocumentRenderer()
        renderer.highlighter = custom
        let start = try doc("abc", language: "x")
        var rendered = renderer.render(start)
        XCTAssertEqual(custom.calls.count, 1)
        // Typing in the paragraph keeps the code block node, so it is not highlighted again.
        let typed = try Transform(start).insert(3, schema.text("!")).doc
        _ = renderer.update(&rendered, to: typed)
        XCTAssertEqual(custom.calls.count, 1)
        // Inside the code block, after "abc": the paragraph "hi!" ends at 5 and the code text starts at 6.
        _ = renderer.update(&rendered, to: try Transform(typed).insert(9, schema.text("d")).doc)
        XCTAssertEqual(custom.calls, ["abc", "abcd"])
    }
}
