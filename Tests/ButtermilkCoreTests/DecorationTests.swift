import Foundation
import XCTest
@testable import ButtermilkCore

final class DecorationTests: XCTestCase {
    let key = NSAttributedString.Key("test")

    func makeDoc(_ texts: String...) throws -> Node {
        try testSchema.nodeFromJSON(["type": "doc", "content": .array(texts.map {
            ["type": "paragraph", "content": [["type": "text", "text": .string($0)]]]
        })])
    }

    func state(_ doc: Node) throws -> EditorState { try EditorState.create(.init(doc: doc)) }

    func testCreateSortsAndDropsOutOfRange() throws {
        let doc = try makeDoc("hello")
        let set = DecorationSet.create(doc, [.inline(3, 5, [key: 1]), .widget(1, "x"), .inline(2, 99, [:])])
        XCTAssertEqual(set.all.map(\.from), [1, 3])
        XCTAssertEqual(set.find(4, 6).count, 1)
        XCTAssertEqual(set.find(nil, nil) { $0["id"] as? Int == 1 }.count, 0)
    }

    func testInlineMapsWithInclusiveEdges() throws {
        let doc = try makeDoc("hello")
        let plain = Decoration.inline(2, 4, [:]), inclusive = Decoration.inline(2, 4, [:], inclusiveStart: true, inclusiveEnd: true)
        let set = DecorationSet.create(doc, [plain, inclusive])
        let s = try state(doc)
        let atStart = try s.tr.insertText("ab", 2, 2), atEnd = try s.tr.insertText("ab", 4, 4)
        let a = set.map(atStart.mapping, atStart.doc).all, b = set.map(atEnd.mapping, atEnd.doc).all
        XCTAssertEqual(a.first { $0.kind === plain.kind }.map { [$0.from, $0.to] }, [4, 6])
        XCTAssertEqual(a.first { $0.kind === inclusive.kind }.map { [$0.from, $0.to] }, [2, 6])
        XCTAssertEqual(b.first { $0.kind === plain.kind }.map { [$0.from, $0.to] }, [2, 4])
        XCTAssertEqual(b.first { $0.kind === inclusive.kind }.map { [$0.from, $0.to] }, [2, 6])
    }

    func testInlineDisappearsWhenItsTextIsDeleted() throws {
        let doc = try makeDoc("hello")
        let set = DecorationSet.create(doc, [.inline(2, 4, [:])])
        let tr = try state(doc).tr.delete(1, 5)
        XCTAssertTrue(set.map(tr.mapping, tr.doc).isEmpty)
    }

    func testNodeDecorationFollowsItsNode() throws {
        let doc = try makeDoc("one", "two")
        let set = DecorationSet.create(doc, [.node(5, 10, [key: 1])])
        let insert = try state(doc).tr.insertText("xx", 1, 1)
        XCTAssertEqual(set.map(insert.mapping, insert.doc).all.map { [$0.from, $0.to] }, [[7, 12]])
        let delete = try state(doc).tr.delete(5, 10)
        XCTAssertTrue(set.map(delete.mapping, delete.doc).isEmpty)
    }

    func testWidgetMapsBySide() throws {
        let doc = try makeDoc("hello")
        let before = Decoration.widget(3, "b", side: -1), after = Decoration.widget(3, "a", side: 1)
        let set = DecorationSet.create(doc, [before, after])
        let tr = try state(doc).tr.insertText("xy", 3, 3)
        let mapped = set.map(tr.mapping, tr.doc).all
        XCTAssertEqual(mapped.first { $0.kind === before.kind }?.from, 3)
        XCTAssertEqual(mapped.first { $0.kind === after.kind }?.from, 5)
        let del = try state(doc).tr.delete(2, 5)
        XCTAssertTrue(set.map(del.mapping, del.doc).isEmpty)
    }

    func testAddAndRemove() throws {
        let doc = try makeDoc("hello")
        let a = Decoration.inline(1, 3, [:]), b = Decoration.widget(2, "w")
        let set = DecorationSet.empty.add(doc, [a, b])
        XCTAssertEqual(set.all, [a, b])
        XCTAssertEqual(set.remove([a]).all, [b])
        XCTAssertNotEqual(Decoration.inline(1, 3, [:]), a, "equality uses kind identity")
    }
}
