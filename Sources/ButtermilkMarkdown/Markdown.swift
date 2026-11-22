import ButtermilkCore
import Foundation
import Markdown

/// Converts between Markdown text and documents, using Apple's swift-markdown (cmark-gfm).
///
/// ```swift
/// let doc = try MarkdownConverter().parse("# Hello\n\nSome *text*.")
/// let text = MarkdownConverter().serialize(doc)
/// ```
///
/// The schema must use the node and mark names of ``MarkdownSchema``. Markdown that has no node
/// in the schema (raw HTML, for example) becomes plain text.
///
/// YAML front matter (a block between `---` lines at the very start) becomes a `front_matter`
/// node holding the raw YAML, which is written back unchanged.
public struct MarkdownConverter {
    public let schema: Schema

    public init(schema: Schema = MarkdownSchema.schema) { self.schema = schema }

    // MARK: Parsing

    /// Parses Markdown into a document.
    public func parse(_ markdown: String) throws -> ButtermilkCore.Node {
        var body = markdown
        var blocks: [ButtermilkCore.Node] = []
        if schema.nodes["front_matter"] != nil, let (yaml, rest) = Self.splitFrontMatter(markdown) {
            blocks.append(try node("front_matter", nil, yaml.isEmpty ? [] : [schema.text(yaml)]))
            body = rest
        }
        let document = Document(parsing: body, options: [.disableSmartOpts])
        blocks += try document.blockChildren.flatMap { try block($0) }
        if blocks.isEmpty, let paragraph = schema.nodes["paragraph"] { blocks = [try paragraph.create()] }
        return try schema.topNodeType.createChecked(nil, Fragment.fromArray(blocks))
    }

    /// Splits `---` fenced front matter off the start of `markdown`. The closing fence may be
    /// `---` or `...`. Returns the YAML without the fences and the remaining Markdown.
    static func splitFrontMatter(_ markdown: String) -> (yaml: String, rest: String)? {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)[...]
        func trimmed(_ line: Substring) -> Substring { line.hasSuffix("\r") ? line.dropLast() : line }
        guard let first = lines.first, trimmed(first) == "---" else { return nil }
        lines = lines.dropFirst()
        guard let end = lines.firstIndex(where: { trimmed($0) == "---" || trimmed($0) == "..." }) else { return nil }
        let yaml = lines[lines.startIndex..<end].joined(separator: "\n")
        return (yaml, lines[(end + 1)...].joined(separator: "\n"))
    }

    private func node(_ name: String, _ attrs: Attrs? = nil, _ content: [ButtermilkCore.Node] = []) throws -> ButtermilkCore.Node {
        guard let type = schema.nodes[name] else { throw ProseError.range("Schema has no node type \(name)") }
        return try type.create(attrs, Fragment.fromArray(content))
    }

    private func block(_ markup: Markup) throws -> [ButtermilkCore.Node] {
        switch markup {
        case let p as Paragraph:
            return [try node("paragraph", nil, inline(p))]
        case let h as Heading:
            return [try node("heading", ["level": h.level.json], inline(h))]
        case let q as BlockQuote:
            return [try node("blockquote", nil, children(q))]
        case let c as CodeBlock:
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            let text = code.isEmpty ? [] : [schema.text(code)]
            return [try node("code_block", ["language": .string(c.language ?? "")], text)]
        case is ThematicBreak:
            return [try node("horizontal_rule")]
        case let list as UnorderedList:
            return [try node("bullet_list", ["spread": .bool(Self.spread(Array(list.listItems)))], list.listItems.map(listItem))]
        case let list as OrderedList:
            return [try node("ordered_list", ["order": Int(list.startIndex).json, "spread": .bool(Self.spread(Array(list.listItems)))],
                             list.listItems.map(listItem))]
        case let table as Markdown.Table:
            return [try self.table(table)]
        case let html as HTMLBlock:
            var raw = html.rawHTML
            if raw.hasSuffix("\n") { raw.removeLast() }
            // Comments (such as the separator between two lists) carry no content.
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->") { return [] }
            return [try node("paragraph", nil, raw.isEmpty ? [] : [schema.text(raw)])]
        default:
            return try markup.children.flatMap { try block($0) }
        }
    }

    private func children(_ markup: Markup) throws -> [ButtermilkCore.Node] {
        var out = try markup.children.flatMap { try block($0) }
        if out.isEmpty { out = [try node("paragraph")] }
        return out
    }

    private func listItem(_ item: ListItem) throws -> ButtermilkCore.Node {
        var content = try item.children.flatMap { try block($0) }
        // List items start with a paragraph.
        if content.first?.type.name != "paragraph" { content.insert(try node("paragraph"), at: 0) }
        var attrs: Attrs = ["spread": .bool(Self.spread(Array(item.children)))]
        if let box = item.checkbox { attrs["checked"] = .bool(box == .checked) }
        return try node("list_item", attrs, content)
    }

    /// Whether a blank line separates any two of `siblings`, as in a loose list.
    static func spread(_ siblings: [Markup]) -> Bool {
        zip(siblings, siblings.dropFirst()).contains { a, b in
            guard let end = lastLine(a), let start = b.range?.lowerBound.line else { return false }
            return start > end + 1
        }
    }

    /// The last line with content in `markup`. A list item's own range includes blank lines after it.
    private static func lastLine(_ markup: Markup) -> Int? {
        if let last = markup.children.reversed().first(where: { _ in true }) { return lastLine(last) }
        guard let end = markup.range?.upperBound else { return nil }
        return end.column == 1 ? end.line - 1 : end.line
    }

    private func table(_ table: Markdown.Table) throws -> ButtermilkCore.Node {
        let alignments = table.columnAlignments
        func cells(_ cells: [Markdown.Table.Cell], header: Bool) throws -> [ButtermilkCore.Node] {
            try cells.enumerated().compactMap { i, cell in
                // cmark-gfm marks cells covered by a span with a span of 0.
                if cell.colspan == 0 || cell.rowspan == 0 { return nil }
                var attrs: Attrs = ["colspan": Int(cell.colspan).json, "rowspan": Int(cell.rowspan).json]
                if i < alignments.count, let a = alignments[i] {
                    attrs["alignment"] = .string(a == .left ? "left" : a == .center ? "center" : "right")
                }
                return try node(header ? "table_header" : "table_cell", attrs, [node("paragraph", nil, inline(cell))])
            }
        }
        var rows = [try node("table_row", nil, cells(Array(table.head.cells), header: true))]
        for row in table.body.rows { rows.append(try node("table_row", nil, cells(Array(row.cells), header: false))) }
        return try node("table", nil, rows)
    }

    private func inline(_ markup: Markup, _ marks: [Mark] = []) throws -> [ButtermilkCore.Node] {
        var out: [ButtermilkCore.Node] = []
        func text(_ s: String, _ marks: [Mark]) {
            guard !s.isEmpty else { return }
            // Merge with the previous text node when the marks match.
            if let last = out.last, last.isText, last.marks == marks, let lastText = last.text {
                out[out.count - 1] = schema.text(lastText + s, marks: marks)
            } else {
                out.append(schema.text(s, marks: marks))
            }
        }
        func mark(_ name: String, _ attrs: Attrs? = nil) throws -> [Mark] {
            guard let type = schema.marks[name] else { return marks }
            return try type.create(attrs).addToSet(marks)
        }
        for child in markup.children {
            switch child {
            case let t as Markdown.Text: text(t.string, marks)
            case is SoftBreak: text(" ", marks)
            case is LineBreak:
                if let br = schema.nodes["hard_break"] { out.append(try br.create(nil, Fragment.empty, marks: marks)) }
            case let c as InlineCode: text(c.code, try mark("code"))
            case let h as InlineHTML: text(h.rawHTML, marks)
            case let e as Emphasis: out += try inline(e, try mark("em")).flatMap(merge)
            case let s as Strong: out += try inline(s, try mark("strong")).flatMap(merge)
            case let s as Strikethrough: out += try inline(s, try mark("strike_through")).flatMap(merge)
            case let l as Markdown.Link:
                var attrs: Attrs = ["href": .string(l.destination ?? "")]
                if let title = l.title { attrs["title"] = .string(title) }
                out += try inline(l, try mark("link", attrs)).flatMap(merge)
            case let img as Markdown.Image:
                var attrs: Attrs = ["src": .string(img.source ?? ""), "alt": .string(img.plainText)]
                if let title = img.title { attrs["title"] = .string(title) }
                if let type = schema.nodes["image"] { out.append(try type.create(attrs, Fragment.empty, marks: marks)) }
            default:
                out += try inline(child, marks).flatMap(merge)
            }
        }
        func merge(_ node: ButtermilkCore.Node) -> [ButtermilkCore.Node] {
            if node.isText, let last = out.last, last.isText, last.marks == node.marks, let a = last.text, let b = node.text {
                out[out.count - 1] = schema.text(a + b, marks: node.marks)
                return []
            }
            return [node]
        }
        return out
    }

    // MARK: Serializing

    /// Serializes a document to Markdown, in the style of Milkdown's remark serializer.
    public func serialize(_ doc: ButtermilkCore.Node) -> String {
        MarkdownWriter().document(doc)
    }
}
