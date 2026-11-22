import Foundation
import XCTest
@testable import ButtermilkCore

final class KillRingTests: XCTestCase {
    func makeState(_ blocks: [JSON], cursor: Int, capacity: Int = 60) throws -> EditorState {
        let doc = try testSchema.nodeFromJSON(["type": "doc", "content": .array(blocks)])
        var config = EditorState.Config(doc: doc, plugins: [KillRing.plugin(capacity: capacity)])
        config.selection = TextSelection.create(doc, cursor)
        return try EditorState.create(config)
    }

    func para(_ text: String) -> JSON {
        text.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": [["type": "text", "text": .string(text)]]]
    }

    func run(_ state: EditorState, _ command: Command) -> EditorState? {
        var out: EditorState?
        _ = command(state, { out = try? state.apply($0) }, nil)
        return out
    }

    func text(_ state: EditorState) -> String { state.doc.textBetween(0, state.doc.content.size, blockSeparator: "|") }
    func entries(_ state: EditorState) -> [String] {
        KillRing.getState(state)!.entries.map { $0.content.textBetween(0, $0.content.size, blockSeparator: "|") }
    }

    func testKillLineAndBoundaryAppend() throws {
        var state = try makeState([para("one two"), para("three")], cursor: 5)
        state = run(state, KillRing.killToEndOfTextblock)!
        XCTAssertEqual(text(state), "one |three")
        state = run(state, KillRing.killToEndOfTextblock)!
        XCTAssertEqual(text(state), "one three", "kills the block boundary at the end")
        state = run(state, KillRing.killToEndOfTextblock)!
        XCTAssertEqual(text(state), "one ")
        XCTAssertEqual(entries(state), ["two|three"])
        XCTAssertNil(run(state, KillRing.killToEndOfTextblock), "nothing left to kill")

        state = try state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1)))
        state = run(state, KillRing.yank)!
        XCTAssertEqual(text(state), "two|threeone ", "yank keeps the paragraph break")
        XCTAssertEqual(state.doc.childCount, 2)
    }

    func testKillWordsPrependBackward() throws {
        var state = try makeState([para("alpha beta gamma")], cursor: 12)
        state = run(state, KillRing.killWordBackward)!
        XCTAssertEqual(text(state), "alpha gamma")
        state = run(state, KillRing.killWordBackward)!
        XCTAssertEqual(text(state), "gamma")
        XCTAssertEqual(entries(state), ["alpha beta "])
        state = run(state, KillRing.killWordForward)!
        XCTAssertEqual(text(state), "")
        XCTAssertEqual(entries(state), ["alpha beta gamma"], "forward kill appends")
    }

    func testNonConsecutiveKillsMakeNewEntriesAndYankPop() throws {
        var state = try makeState([para("ab cd")], cursor: 1)
        state = run(state, KillRing.killWordForward)!
        state = try state.apply(state.tr.insertText("x", 1, 1))
        state = run(state, KillRing.killWordForward)!
        XCTAssertEqual(entries(state), [" cd", "ab"])
        XCTAssertEqual(text(state), "x")
        XCTAssertNil(run(state, KillRing.yankPop), "yank-pop needs a yank first")
        state = run(state, KillRing.yank)!
        XCTAssertEqual(text(state), "x cd")
        state = run(state, KillRing.yankPop)!
        XCTAssertEqual(text(state), "xab")
        state = run(state, KillRing.yankPop)!
        XCTAssertEqual(text(state), "x cd", "wraps around")
    }

    func testKillRegionKeepsMarksAndRingIsBounded() throws {
        let bold: JSON = ["type": "paragraph", "content": [["type": "text", "text": "bold", "marks": [["type": "strong"]]], ["type": "text", "text": " plain"]]]
        var state = try makeState([bold], cursor: 1, capacity: 2)
        state = try state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1, 5)))
        state = run(state, KillRing.killRegion)!
        XCTAssertEqual(text(state), " plain")
        state = try state.apply(state.tr.setSelection(TextSelection.create(state.doc, 7)))
        state = run(state, KillRing.yank)!
        XCTAssertEqual(text(state), " plainbold")
        XCTAssertEqual(state.doc.firstChild!.lastChild!.marks.map(\.type.name), ["strong"])

        for _ in 0..<3 {
            state = try state.apply(state.tr.insertText("w", 1, 1))
            state = run(state, KillRing.killWordBackward)!
        }
        XCTAssertEqual(KillRing.getState(state)!.entries.count, 2)
    }

    func testWithoutPluginKillDeletesAndYankFails() throws {
        let doc = try testSchema.nodeFromJSON(["type": "doc", "content": [para("abc")]])
        var config = EditorState.Config(doc: doc)
        config.selection = TextSelection.create(doc, 2)
        let state = try EditorState.create(config)
        XCTAssertEqual(text(run(state, KillRing.killToEndOfTextblock)!), "a")
        XCTAssertNil(run(state, KillRing.yank))
    }
}
