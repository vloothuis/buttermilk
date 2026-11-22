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
public struct MarkdownConverter {
    public let schema: Schema

    public init(schema: Schema = MarkdownSchema.schema) { self.schema = schema }

    // MARK: Parsing

    /// Parses Markdown into a document.
    public func parse(_ markdown: String) throws -> ButtermilkCore.Node {
        let document = Document(parsing: markdown)
        var blocks = try document.blockChildren.flatMap { try block($0) }
        if blocks.isEmpty, let paragraph = schema.nodes["paragraph"] { blocks = [try paragraph.create()] }
        return try schema.topNodeType.createChecked(nil, Fragment.fromArray(blocks))
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
            return [try node("bullet_list", nil, list.listItems.map(listItem))]
        case let list as OrderedList:
            return [try node("ordered_list", ["order": Int(list.startIndex).json], list.listItems.map(listItem))]
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
        var attrs: Attrs = [:]
        if let box = item.checkbox { attrs["checked"] = .bool(box == .checked) }
        return try node("list_item", attrs, content)
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

    /// Serializes a document to Markdown.
    ///
    /// Top-level blocks are formatted one at a time, because swift-markdown's formatter numbers
    /// every ordered list the same way. Nested ordered lists always start at 1.
    public func serialize(_ doc: ButtermilkCore.Node) -> String {
        var parts: [String] = []
        var previous: String?
        doc.forEach { child, _, _ in
            let name = child.type.name
            // Two lists of the same kind in a row would parse back as one list.
            if previous == name, name == "bullet_list" || name == "ordered_list" { parts.append("<!-- -->") }
            previous = name
            var options = MarkupFormatter.Options()
            if name == "ordered_list" {
                options = MarkupFormatter.Options(orderedListNumerals: .incrementing(start: UInt(max(child.attrs["order"]?.intValue ?? 1, 0))))
            }
            for block in blockMarkup(child) {
                var text = Document([block]).format(options: options)
                while text.hasSuffix("\n") { text.removeLast() }
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private func childBlocks(_ node: ButtermilkCore.Node) -> [BlockMarkup] {
        var out: [BlockMarkup] = []
        node.forEach { child, _, _ in out += blockMarkup(child) }
        return out
    }

    private func blockMarkup(_ node: ButtermilkCore.Node) -> [BlockMarkup] {
        switch node.type.name {
        case "paragraph":
            return [Paragraph(inlineMarkup(node))]
        case "heading":
            return [Heading(level: min(max(node.attrs["level"]?.intValue ?? 1, 1), 6), inlineMarkup(node))]
        case "blockquote":
            return [BlockQuote(childBlocks(node))]
        case "code_block":
            let language = node.attrs["language"]?.stringValue ?? ""
            return [CodeBlock(language: language.isEmpty ? nil : language, node.textContent + "\n")]
        case "horizontal_rule":
            return [ThematicBreak()]
        case "bullet_list":
            return [UnorderedList(listItems(node))]
        case "ordered_list":
            var list = OrderedList(listItems(node))
            list.startIndex = UInt(max(node.attrs["order"]?.intValue ?? 1, 0))
            return [list]
        case "table":
            return [table(node)]
        default:
            if node.isTextblock { return [Paragraph(inlineMarkup(node))] }
            return childBlocks(node)
        }
    }

    private func listItems(_ list: ButtermilkCore.Node) -> [ListItem] {
        var items: [ListItem] = []
        list.forEach { item, _, _ in
            var li = ListItem(childBlocks(item))
            if let checked = item.attrs["checked"]?.boolValue { li.checkbox = checked ? .checked : .unchecked }
            items.append(li)
        }
        return items
    }

    private func table(_ node: ButtermilkCore.Node) -> Markdown.Table {
        var rows: [[Markdown.Table.Cell]] = []
        var alignments: [Markdown.Table.ColumnAlignment?] = []
        node.forEach { row, _, rowIndex in
            var cells: [Markdown.Table.Cell] = []
            row.forEach { cell, _, _ in
                var inline: [InlineMarkup] = []
                cell.forEach { block, _, index in
                    if index > 0 { inline.append(LineBreak()) }
                    inline += inlineMarkup(block)
                }
                var c = Markdown.Table.Cell(inline)
                c.colspan = UInt(min(max(cell.attrs["colspan"]?.intValue ?? 1, 1), Tables.maxCellSpan))
                cells.append(c)
                // Covered columns get empty cells with a span of 0.
                for _ in 1..<Int(c.colspan) { var gap = Markdown.Table.Cell([]); gap.colspan = 0; cells.append(gap) }
                if rowIndex == 0 {
                    let a: Markdown.Table.ColumnAlignment? = switch cell.attrs["alignment"]?.stringValue {
                    case "left": .left
                    case "center": .center
                    case "right": .right
                    default: nil
                    }
                    alignments += Array(repeating: a, count: Int(c.colspan))
                }
            }
            rows.append(cells)
        }
        let head = Markdown.Table.Head(rows.first ?? [])
        let body = Markdown.Table.Body(rows.dropFirst().map { Markdown.Table.Row($0) })
        return Markdown.Table(columnAlignments: alignments, header: head, body: body)
    }

    /// Turns inline content with flat mark sets into nested Markdown elements.
    private func inlineMarkup(_ parent: ButtermilkCore.Node) -> [InlineMarkup] {
        var items: [(ButtermilkCore.Node, [Mark])] = []
        parent.forEach { child, _, _ in items.append((child, child.marks)) }
        return nest(items[...])
    }

    private func nest(_ items: ArraySlice<(ButtermilkCore.Node, [Mark])>) -> [InlineMarkup] {
        var out: [InlineMarkup] = []
        var i = items.startIndex
        while i < items.endIndex {
            let (node, marks) = items[i]
            // Code marks become the innermost element, since inline code cannot contain markup.
            guard let outer = marks.first(where: { !$0.type.spec.code }) else {
                out.append(leaf(node, code: !marks.isEmpty))
                i += 1
                continue
            }
            var j = i
            var run: [(ButtermilkCore.Node, [Mark])] = []
            while j < items.endIndex, items[j].1.contains(outer) {
                run.append((items[j].0, items[j].1.filter { $0 != outer }))
                j += 1
            }
            out += wrap(outer, nest(run[...]))
            i = j
        }
        return out
    }

    private func leaf(_ node: ButtermilkCore.Node, code: Bool) -> InlineMarkup {
        if let text = node.text { return code ? InlineCode(text) : Markdown.Text(text) }
        switch node.type.name {
        case "hard_break", "hardbreak": return LineBreak()
        case "image":
            return Markdown.Image(source: node.attrs["src"]?.stringValue ?? "", title: node.attrs["title"]?.stringValue,
                                  [Markdown.Text(node.attrs["alt"]?.stringValue ?? "")])
        default: return Markdown.Text(node.textContent)
        }
    }

    /// Marks Markdown has no syntax for are dropped; their content stays.
    private func wrap(_ mark: Mark, _ children: [InlineMarkup]) -> [InlineMarkup] {
        switch mark.type.name {
        case "em", "emphasis": return [Emphasis(children)]
        case "strong": return [Strong(children)]
        case "strike_through", "strikethrough": return [Strikethrough(children)]
        case "link":
            return [Markdown.Link(destination: mark.attrs["href"]?.stringValue, title: mark.attrs["title"]?.stringValue, children.compactMap { $0 as? RecurringInlineMarkup })]
        default:
            return children
        }
    }
}
