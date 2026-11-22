import Foundation
import XCTest
@testable import ButtermilkCore

final class UndoNameTests: XCTestCase {
    func makeState(_ text: String, cursor: Int, plugins: [Plugin] = []) throws -> EditorState {
        let doc = try testSchema.nodeFromJSON(["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]]])
        var config = EditorState.Config(doc: doc, plugins: [History.plugin()] + plugins)
        config.selection = TextSelection.create(doc, cursor)
        return try EditorState.create(config)
    }

    func run(_ state: EditorState, _ command: Command) -> EditorState? {
        var out: EditorState?
        _ = command(state, { out = try? state.apply($0) }, nil)
        return out
    }

    /// Runs `command` with its transactions starting a new history event.
    func closed(_ command: @escaping Command) -> Command {
        { state, dispatch, view in command(state, dispatch.map { d in { d(History.closeHistory($0)) } }, view) }
    }

    func testEventsRecordTheirNames() throws {
        var state = try makeState("abc", cursor: 4)
        XCTAssertNil(History.undoActionName(state))
        state = try state.apply(state.tr.insertText("d").setActionName("Typing"))
        XCTAssertEqual(History.undoActionName(state), "Typing")
        state = try state.apply(History.closeHistory(state.tr.insertText("e").setActionName("Paste")))
        XCTAssertEqual(History.undoActionName(state), "Paste")

        state = run(state, History.undo)!
        XCTAssertEqual(History.undoActionName(state), "Typing")
        XCTAssertEqual(History.redoActionName(state), "Paste")
        state = run(state, History.undo)!
        XCTAssertNil(History.undoActionName(state))
        XCTAssertEqual(History.redoActionName(state), "Typing")
        state = run(state, History.redo)!
        XCTAssertEqual(History.undoActionName(state), "Typing")
        XCTAssertEqual(History.redoActionName(state), "Paste")
    }

    func testGroupedEventKeepsTheFirstName() throws {
        var state = try makeState("abc", cursor: 4)
        state = try state.apply(state.tr.insertText("d").setActionName("Typing"))
        state = try state.apply(state.tr.insertText("e").setActionName("Delete"))
        XCTAssertEqual(History.undoDepth(state), 1)
        XCTAssertEqual(History.undoActionName(state), "Typing")
    }

    func testUnnamedEventHasNoName() throws {
        var state = try makeState("abc", cursor: 4)
        state = try state.apply(state.tr.insertText("d"))
        XCTAssertEqual(History.undoDepth(state), 1)
        XCTAssertNil(History.undoActionName(state))
    }

    func testBuiltInCommandsNameTheirChanges() throws {
        var state = try makeState("abc", cursor: 1)
        state = try state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1, 3)))
        state = run(state, Commands.toggleMark(testSchema.marks["strong"]!))!
        XCTAssertEqual(History.undoActionName(state), "Formatting")

        state = try makeState("one two", cursor: 4, plugins: [KillRing.plugin()])
        state = run(state, KillRing.killToEndOfTextblock)!
        XCTAssertEqual(History.undoActionName(state), "Kill")
        state = run(state, closed(KillRing.yank))!
        XCTAssertEqual(History.undoActionName(state), "Yank")
    }

    func testNamedKeepsAnExistingName() throws {
        let state = try makeState("abc", cursor: 4)
        var name: String?
        let inner = Commands.named("Inner") { state, dispatch, _ in if let tr = try? state.tr.insertText("x") { dispatch?(tr) }; return true }
        _ = Commands.named("Outer", inner)(state, { name = $0.actionName }, nil)
        XCTAssertEqual(name, "Inner")
    }
}
