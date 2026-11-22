import ButtermilkCore
@testable import ButtermilkMarkdown
import XCTest

final class MarkdownTests: XCTestCase {
    let md = MarkdownConverter()

    func testParsesStructure() throws {
        let doc = try md.parse("""
        # Title

        Some *em*, **strong**, `code`, ~~gone~~ and [a link](https://example.com "T").

        - one
        - [x] done

        3. three
        4. four

        > quoted

        ```swift
        let x = 1
        ```

        ---

        | A | B |
        |:--|--:|
        | 1 | 2 |
        """)
        let names = (0..<doc.childCount).map { doc.child($0).type.name }
        XCTAssertEqual(names, ["heading", "paragraph", "bullet_list", "ordered_list", "blockquote", "code_block", "horizontal_rule", "table"])
        let para = doc.child(1)
        var marks: [String: String] = [:]
        para.forEach { child, _, _ in for m in child.marks { marks[m.type.name] = child.text } }
        XCTAssertEqual(marks, ["em": "em", "strong": "strong", "code": "code", "strike_through": "gone", "link": "a link"])
        XCTAssertEqual(doc.child(2).child(1).attrs["checked"], .bool(true))
        XCTAssertEqual(doc.child(2).child(0).attrs["checked"], .null)
        XCTAssertEqual(doc.child(3).attrs["order"], 3)
        XCTAssertEqual(doc.child(5).attrs["language"], "swift")
        XCTAssertEqual(doc.child(5).textContent, "let x = 1")
        let table = doc.child(7)
        XCTAssertEqual(table.child(0).child(0).type.name, "table_header")
        XCTAssertEqual(table.child(0).child(0).attrs["alignment"], "left")
        XCTAssertEqual(table.child(1).child(1).attrs["alignment"], "right")
        XCTAssertNoThrow(try doc.check())
    }

    func testRoundTrips() throws {
        let samples = [
            "# Title\n\nText with *em*, **strong** and `code`.\n",
            "- a\n- b\n  - nested\n",
            "1. first\n2. second\n",
            "3. three\n4. four\n",
            "- a\n\n<!-- -->\n\n- b\n",
            "> quote\n>\n> more\n",
            "```js\nconsole.log(1)\n```\n",
            "Hard  \nbreak\n",
            "[**bold link**](https://x.dev)\n",
            "- [ ] todo\n- [x] done\n",
            "***both***\n",
            "![alt](img.png \"title\")\n",
            "|A|B|\n|-|-|\n|1|2|\n",
        ]
        for sample in samples {
            let doc = try md.parse(sample)
            let text = md.serialize(doc)
            let again = try md.parse(text)
            XCTAssertEqual(again.toJSON(), doc.toJSON(), "round trip changed the document:\n\(sample)\n→\n\(text)")
        }
    }

    func testSerializesNestedMarks() throws {
        let s = MarkdownSchema.schema
        let strong = s.marks["strong"]!.create(), em = s.marks["em"]!.create(), code = s.marks["code"]!.create()
        let doc = try s.node("doc", nil, [s.node("paragraph", nil, [
            s.text("a", marks: [strong]), s.text("b", marks: em.addToSet([strong])), s.text("c", marks: code.addToSet([strong])),
        ])])
        XCTAssertEqual(md.serialize(doc), "**a*b*`c`**\n")
    }

    func testAdjacentListsStaySeparate() throws {
        let doc = try md.parse("- a\n\n<!-- -->\n\n- b\n")
        XCTAssertEqual((0..<doc.childCount).map { doc.child($0).type.name }, ["bullet_list", "bullet_list"])
        XCTAssertEqual(md.serialize(doc), "- a\n\n<!-- -->\n\n- b\n")
    }

    func testEmptyDocument() throws {
        let doc = try md.parse("")
        XCTAssertEqual(doc.childCount, 1)
        XCTAssertEqual(doc.child(0).type.name, "paragraph")
    }
}
