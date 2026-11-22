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
            "1. a\n   3. nested\n   4. start\n",
            "- loose\n\n- list\n",
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
        XCTAssertEqual(md.serialize(doc), "* a\n\n- b\n")
    }

    func testEmptyDocument() throws {
        let doc = try md.parse("")
        XCTAssertEqual(doc.childCount, 1)
        XCTAssertEqual(doc.child(0).type.name, "paragraph")
    }
}

final class MarkdownSafetyTests: XCTestCase {
    func testOutOfRangeAttributesAreClamped() throws {
        let s = MarkdownSchema.schema
        let doc = try s.node("doc", nil, [s.node("heading", ["level": 99], [s.text("x")])])
        XCTAssertEqual(MarkdownConverter().serialize(doc), "###### x\n")
    }

    let md = MarkdownConverter()

    func testFrontMatterRoundTripsUnchanged() throws {
        let yaml = "title: \"Hello: world\"\ntags:\n  - a\n  - b   \n# comment\n\nnested:\n    key: *ref"
        let text = "---\n\(yaml)\n---\n\n# Body\n"
        let doc = try md.parse(text)
        XCTAssertEqual(doc.child(0).type.name, "front_matter")
        XCTAssertEqual(doc.child(0).textContent, yaml)
        XCTAssertEqual(doc.child(1).type.name, "heading")
        XCTAssertEqual(md.serialize(doc), text)
    }

    func testFrontMatterEdgeCases() throws {
        // Dots close front matter too; it is written back with dashes.
        XCTAssertEqual(try md.parse("---\na: 1\n...\nText\n").child(0).textContent, "a: 1")
        // Empty front matter and a document with only front matter.
        let empty = try md.parse("---\n---\n")
        XCTAssertEqual(empty.child(0).type.name, "front_matter")
        XCTAssertEqual(md.serialize(empty), "---\n---\n")
        // A rule not at the very start, or without a closing fence, is not front matter.
        XCTAssertEqual(try md.parse("Text\n\n---\na: 1\n---\n").child(0).type.name, "paragraph")
        XCTAssertNotEqual(try md.parse("---\nText\n").child(0).type.name, "front_matter")
        // Front matter moved away from the start is written as a YAML code block.
        let s = MarkdownSchema.schema
        let moved = try s.node("doc", nil, [s.node("paragraph", nil, [s.text("x")]),
                                            s.node("front_matter", nil, [s.text("a: 1")])])
        XCTAssertEqual(md.serialize(moved), "x\n\n```yaml\na: 1\n```\n")
    }

    func testFrontMatterCannotBreakOut() throws {
        let s = MarkdownSchema.schema
        for yaml in ["a: 1\n---\n<script>x</script>", "a: 1\r\n...\r\n<script>x</script>", "```\n---\n<script>x</script>"] {
            let doc = try s.node("doc", nil, [s.node("front_matter", nil, [s.text(yaml)])])
            let back = try md.parse(md.serialize(doc))
            XCTAssertEqual(back.childCount, 1)
            XCTAssertEqual(back.child(0).type.name, "code_block")
            XCTAssertEqual(back.child(0).attrs["language"]?.stringValue, "yaml")
            XCTAssertEqual(back.child(0).textContent, yaml.replacingOccurrences(of: "\r\n", with: "\n"))
        }
    }

}
