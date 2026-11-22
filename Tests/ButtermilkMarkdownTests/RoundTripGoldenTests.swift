import ButtermilkMarkdown
import Foundation
import XCTest

/// Compares Buttermilk's parse and serialize round trip with Milkdown's, on the corpus in
/// `golden/markdown-corpus`. `golden/gen-markdown.mjs` writes Milkdown's output.
final class RoundTripGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let input: String; let milkdown: String }

    /// The intentional differences from `docs/markdown-round-trip.md`, as replacements that turn
    /// Milkdown's output into Buttermilk's.
    static let differences: [String: [(milkdown: String, buttermilk: String)]] = [
        "blocks": [("> A quote\n> over two lines.", "> A quote over two lines.")],
        "edge-cases": [("<!-- -->\n\n1. again", "1) again"), ("* <br />", "*")],
        "frontmatter": [("***\n\ntitle: Hello\ntags: \\[a, b]\n-------------", "---\ntitle: Hello\ntags: [a, b]\n---")],
        "inline": [("_underscore emphasis_", "*underscore emphasis*"), ("__underscore strong__", "**underscore strong**")],
    ]

    let md = MarkdownConverter()

    func cases() throws -> [Case] {
        let url = Bundle.module.url(forResource: "roundtrip", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode([String: [Case]].self, from: Data(contentsOf: url))["cases"]!
    }

    func testMatchesMilkdown() throws {
        let cases = try cases()
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            var expected = c.milkdown
            for (milkdown, buttermilk) in Self.differences[c.name] ?? [] {
                XCTAssertTrue(expected.contains(milkdown), "\(c.name): documented difference not found: \(milkdown)")
                expected = expected.replacingOccurrences(of: milkdown, with: buttermilk)
            }
            XCTAssertEqual(md.serialize(try md.parse(c.input)), expected, c.name)
        }
    }

    /// Writing a document and reading it back gives the same document.
    func testOutputIsStable() throws {
        for c in try cases() {
            let doc = try md.parse(c.input)
            let text = md.serialize(doc)
            XCTAssertEqual(try md.parse(text).toJSON(), doc.toJSON(), c.name)
            XCTAssertEqual(md.serialize(try md.parse(text)), text, c.name)
        }
    }
}
