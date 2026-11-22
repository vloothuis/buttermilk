import XCTest
@testable import ButtermilkCore

final class KeymapTests: XCTestCase {
    func testNormalizeKeyName() throws {
        // Expected values follow prosemirror-keymap's normalizeKeyName, with Mod mapped to Meta (Apple).
        let cases: [(String, String)] = [
            ("a", "a"), ("Space", " "), ("Mod-b", "Meta-b"), ("Shift-Enter", "Shift-Enter"),
            ("Ctrl-Alt-Backspace", "Ctrl-Alt-Backspace"), ("Alt-Ctrl-x", "Ctrl-Alt-x"),
            ("s-c-a-m-y", "Shift-Meta-Ctrl-Alt-y"), ("Mod--", "Meta--"), ("cmd-Shift-z", "Shift-Meta-z"),
        ]
        for (input, expected) in cases { XCTAssertEqual(try Keymap.normalizeKeyName(input), expected, input) }
        XCTAssertThrowsError(try Keymap.normalizeKeyName("Hyper-x"))
    }

    func testHandlerDispatch() throws {
        let schema = testSchema
        let doc = try schema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "hi"]]]]])
        let view = FakeView(try EditorState.create(.init(doc: doc)))
        var log: [String] = []
        func record(_ name: String) -> Command { { _, _, _ in log.append(name); return true } }
        let handler = Keymap.handler(["Mod-b": record("bold"), "Shift-Enter": record("shift-enter"), "x": record("x"),
                                      "Mod-z": record("undo")])

        XCTAssertTrue(handler(view, KeyPress("b", modifiers: .command)))
        XCTAssertTrue(handler(view, KeyPress("Enter", modifiers: .shift)))
        // A shifted character falls back to the binding without Shift.
        XCTAssertTrue(handler(view, KeyPress("x", modifiers: .shift)))
        // A non-Latin layout falls back to the base key.
        XCTAssertTrue(handler(view, KeyPress("я", modifiers: .command, baseKey: "z")))
        XCTAssertFalse(handler(view, KeyPress("q")))
        XCTAssertEqual(log, ["bold", "shift-enter", "x", "undo"])
    }
}
