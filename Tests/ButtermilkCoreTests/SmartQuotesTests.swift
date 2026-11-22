import XCTest
@testable import ButtermilkCore

final class SmartQuotesTests: XCTestCase {
    let schema = testSchema

    /// Type `input` one character at a time into a textblock and return its text.
    func type(_ input: String, rules: [InputRule] = InputRules.smartQuotes + [InputRules.ellipsis, InputRules.emDash],
              block: String = "paragraph", marks: [Mark] = [], then command: Command? = nil) throws -> String {
        let doc = try schema.node("doc", nil, [schema.node(block)])
        let plugin = InputRules.plugin(rules)
        let view = FakeView(try EditorState.create(.init(doc: doc, selection: TextSelection.between(doc.resolve(1), doc.resolve(1)),
                                                         plugins: [plugin])))
        for ch in input {
            let text = String(ch), sel = view.state.selection
            if !plugin.props.handleTextInput!(view, sel.from, sel.to, text) {
                let tr = view.state.tr
                if marks.isEmpty { try tr.insertText(text, sel.from, sel.to) }
                else { try tr.replaceWith(sel.from, sel.to, schema.text(text, marks: marks)) }
                view.dispatch(tr)
            }
        }
        if let command { _ = command(view.state, view.dispatch, view) }
        return view.state.doc.textContent
    }

    func testQuotes() throws {
        XCTAssertEqual(try type("\"Hi,\" she said."), "“Hi,” she said.")
        XCTAssertEqual(try type("'tis Bob's ('one')"), "‘tis Bob’s (‘one’)")
        XCTAssertEqual(try type("\"'nested'\""), "“‘nested’”")
    }

    func testEllipsisAndDash() throws {
        XCTAssertEqual(try type("wait... a--b"), "wait… a—b")
    }

    func testConfigurableQuotes() throws {
        let rules = InputRules.smartQuotes(.init(openDouble: "„", closeDouble: "“", openSingle: "‚", closeSingle: "‘"))
        XCTAssertEqual(try type("\"Ja,\" 's", rules: rules), "„Ja,“ ‚s")
        XCTAssertEqual(try type("\"„\"", rules: rules), "„„„")
    }

    func testNotInCode() throws {
        XCTAssertEqual(try type("\"a\" ... --", block: "code_block"), "\"a\" ... --")
        XCTAssertEqual(try type("x \"a\" ... --", marks: [schema.marks["code"]!.create()]), "x \"a\" ... --")
    }

    func testUndoWithBackspace() throws {
        XCTAssertEqual(try type("a \"", then: InputRules.undoInputRule), "a \"")
        XCTAssertEqual(try type("x...", then: InputRules.undoInputRule), "x...")
    }
}
