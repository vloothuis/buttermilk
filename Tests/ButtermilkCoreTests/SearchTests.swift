import Foundation
import XCTest
@testable import ButtermilkCore

final class SearchTests: XCTestCase {
    func makeState(_ texts: String..., query: SearchQuery? = nil, range: (from: Int, to: Int)? = nil) throws -> EditorState {
        let doc = try testSchema.nodeFromJSON(["type": "doc", "content": .array(texts.map {
            ["type": "paragraph", "content": [["type": "text", "text": .string($0)]]]
        })])
        return try EditorState.create(.init(doc: doc, plugins: [Search.plugin(.init(initialQuery: query, initialRange: range))]))
    }

    func run(_ state: EditorState, _ command: Command) throws -> EditorState? {
        var out: EditorState?
        _ = command(state, { out = try? state.apply($0) }, nil)
        return out
    }

    func sel(_ state: EditorState?) -> [Int] { state.map { [$0.selection.from, $0.selection.to] } ?? [] }
    func text(_ state: EditorState?) -> String { state?.doc.textBetween(0, state!.doc.content.size, blockSeparator: "|") ?? "" }

    func testQueryOptions() throws {
        let state = try makeState("Foo foo food", "a.b")
        XCTAssertEqual(SearchQuery(search: "foo").findAll(state).map(\.from), [1, 5, 9])
        XCTAssertEqual(SearchQuery(search: "foo", caseSensitive: true).findAll(state).map(\.from), [5, 9])
        XCTAssertEqual(SearchQuery(search: "foo", wholeWord: true).findAll(state).map(\.from), [1, 5])
        XCTAssertEqual(SearchQuery(search: ".").findAll(state).map(\.from), [16])
        XCTAssertEqual(SearchQuery(search: "f(o+)d", regexp: true).findAll(state).map { [$0.from, $0.to] }, [[9, 13]])
        XCTAssertFalse(SearchQuery(search: "").valid)
        XCTAssertFalse(SearchQuery(search: "(", regexp: true).valid)
        XCTAssertEqual(SearchQuery(search: "a\\tb").search, "a\\tb")
        XCTAssertEqual(SearchQuery.unquote("a\\tb\\\\n"), "a\tb\\n")
    }

    func testMatchesDoNotCrossBlocks() throws {
        let state = try makeState("ab", "cd")
        XCTAssertTrue(SearchQuery(search: "bc").findAll(state).isEmpty)
    }

    func testFindNextAndPrevWrap() throws {
        var state = try makeState("one x two x", "x three", query: SearchQuery(search: "x"))
        state = try run(state, Search.findNext)!
        XCTAssertEqual(sel(state), [5, 6])
        state = try run(state, Search.findNext)!
        XCTAssertEqual(sel(state), [11, 12])
        state = try run(state, Search.findNext)!
        XCTAssertEqual(sel(state), [14, 15])
        XCTAssertNil(try run(state, Search.findNextNoWrap))
        state = try run(state, Search.findNext)!
        XCTAssertEqual(sel(state), [5, 6], "wraps to the start")
        XCTAssertNil(try run(state, Search.findPrevNoWrap))
        state = try run(state, Search.findPrev)!
        XCTAssertEqual(sel(state), [14, 15], "wraps to the end")
        state = try run(state, Search.findPrev)!
        XCTAssertEqual(sel(state), [11, 12])
    }

    func testDecorationsMarkActiveMatch() throws {
        var state = try makeState("a b a", query: SearchQuery(search: "a"))
        XCTAssertEqual(Search.getMatchHighlights(state).all.map(\.from), [1, 5])
        state = try run(state, Search.findNext)!
        let decos = Search.getMatchHighlights(state).all
        XCTAssertEqual(decos.map { $0.spec["active"] as? Bool }, [true, false])
        XCTAssertNotNil(decos[0].attributes[.activeSearchMatch])
        XCTAssertTrue(state.plugins[0].props.decorations!(state).all == decos)
    }

    func testSetSearchStateAndMapping() throws {
        var state = try makeState("abc abc")
        XCTAssertTrue(Search.getMatchHighlights(state).isEmpty)
        state = try state.apply(Search.setSearchState(state.tr, SearchQuery(search: "abc")))
        XCTAssertEqual(Search.getMatchHighlights(state).all.count, 2)
        state = try state.apply(state.tr.insertText("abc ", 1, 1))
        XCTAssertEqual(Search.getMatchHighlights(state).all.map(\.from), [1, 5, 9])
        XCTAssertNil(try run(try makeState("abc"), Search.findNext), "no query")
    }

    func testRangeLimitsSearch() throws {
        var state = try makeState("x x x x", query: SearchQuery(search: "x"), range: (3, 6))
        XCTAssertEqual(Search.getMatchHighlights(state).all.map(\.from), [3, 5])
        state = try run(state, Search.replaceAll)!
        XCTAssertEqual(text(state), "x   x")
        state = try state.apply(state.tr.insertText("yy", 1, 1))
        XCTAssertEqual(Search.getState(state)!.range!.from, 5, "range is mapped")
    }

    func testReplaceNextAndCurrent() throws {
        var state = try makeState("cat cat cat", query: SearchQuery(search: "cat", replace: "dog"))
        state = try run(state, Search.replaceNext)!
        XCTAssertEqual(sel(state), [1, 4], "first selects a match")
        XCTAssertEqual(text(state), "cat cat cat")
        state = try run(state, Search.replaceNext)!
        XCTAssertEqual(text(state), "dog cat cat")
        XCTAssertEqual(sel(state), [5, 8])
        state = try run(state, Search.replaceCurrent)!
        XCTAssertEqual(text(state), "dog dog cat")
        XCTAssertEqual(sel(state), [8, 8])
        XCTAssertNil(try run(state, Search.replaceCurrent), "selection is not a match")
    }

    func testReplaceAllWithRegexGroupsAndDeletion() throws {
        var state = try makeState("a1 b22", "c3", query: SearchQuery(search: "([a-z])(\\d+)", regexp: true, replace: "$2$1$$$&"))
        state = try run(state, Search.replaceAll)!
        XCTAssertEqual(text(state), "1a$a1 22b$b22|3c$c3")
        state = try makeState("a-b-c", query: SearchQuery(search: "-"))
        state = try run(state, Search.replaceAll)!
        XCTAssertEqual(text(state), "abc")
        XCTAssertNil(try run(state, Search.replaceAll), "no matches left")
    }

    func testReplacementKeepsMarks() throws {
        let schema = testSchema
        let doc = try schema.node("doc", nil, [try schema.node("paragraph", nil, [schema.text("bold", marks: [try schema.mark("strong")])])])
        var state = try EditorState.create(.init(doc: doc, plugins: [Search.plugin(.init(initialQuery: SearchQuery(search: "old", replace: "ig")))]))
        state = try run(state, Search.replaceAll)!
        XCTAssertEqual(text(state), "big")
        XCTAssertEqual(state.doc.firstChild?.firstChild?.marks.map(\.type.name), ["strong"])
    }
}
