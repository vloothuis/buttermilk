import ButtermilkCore
import Foundation

/// Writes documents as Markdown in the style of Milkdown's remark serializer
/// (`mdast-util-to-markdown` with `remark-gfm`): `*` bullets, `***` rules, fenced code,
/// `\` hard breaks and padded tables. `docs/markdown-round-trip.md` lists where the output
/// still differs from Milkdown's.
struct MarkdownWriter {
    func document(_ doc: ButtermilkCore.Node) -> String {
        return blocks(doc, top: true).joined(separator: "\n\n") + "\n"
    }

    // MARK: Blocks

    /// Writes the children of a block container, one string per child.
    private func blocks(_ parent: ButtermilkCore.Node, top: Bool = false) -> [String] {
        var out: [String] = []
        // Adjacent lists of one kind alternate markers, so they do not merge into one list.
        var previous: (name: String, alternate: Bool)?
        parent.forEach { child, _, index in
            let name = child.type.name
            var alternate = false
            if let previous, previous.name == name, name == "bullet_list" || name == "ordered_list" { alternate = !previous.alternate }
            previous = (name, alternate)
            if name == "front_matter" {
                // Front matter only works at the start; elsewhere it becomes a YAML code block.
                // A `---` or `...` line inside the text would close it early.
                let text = child.textContent
                // Swift treats "\r\n" as one Character, so split on both.
                let breaksOut = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).contains {
                    let line = $0.hasSuffix("\r") ? $0.dropLast() : $0
                    return line == "---" || line == "..."
                }
                out.append(top && index == 0 && !breaksOut
                    ? "---\n" + (child.textContent.isEmpty ? "" : child.textContent + "\n") + "---"
                    : codeBlock(child.textContent, language: "yaml"))
            } else {
                out.append(block(child, alternate: alternate))
            }
        }
        return out
    }

    private func block(_ node: ButtermilkCore.Node, alternate: Bool = false) -> String {
        switch node.type.name {
        case "heading":
            let level = min(max(node.attrs["level"]?.intValue ?? 1, 1), 6)
            var text = inline(node, inHeading: true)
            // A closing `#` sequence would be dropped.
            if text.hasSuffix("#") { text.insert("\\", at: text.index(before: text.endIndex)) }
            return String(repeating: "#", count: level) + (text.isEmpty ? "" : " " + text)
        case "blockquote":
            return blocks(node).joined(separator: "\n\n").split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case "code_block":
            return codeBlock(node.textContent, language: node.attrs["language"]?.stringValue ?? "")
        case "horizontal_rule":
            return "***"
        case "bullet_list", "ordered_list":
            return list(node, alternate: alternate)
        case "table":
            return table(node)
        default:
            if node.isTextblock { return inline(node) }
            return blocks(node).joined(separator: "\n\n")
        }
    }

    private func codeBlock(_ code: String, language: String) -> String {
        // The fence must be longer than any backtick run at the start of a line in the code.
        var longest = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            longest = max(longest, line.prefix { $0 == "`" }.count)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + (code.isEmpty ? "" : code + "\n") + fence
    }

    private func list(_ list: ButtermilkCore.Node, alternate: Bool) -> String {
        let ordered = list.type.name == "ordered_list"
        let start = max(list.attrs["order"]?.intValue ?? 1, 0)
        var items: [String] = []
        list.forEach { item, _, index in
            var marker = ordered ? "\(start + index)" + (alternate ? ")" : ".") : (alternate ? "-" : "*")
            if let checked = item.attrs["checked"]?.boolValue { marker += checked ? " [x]" : " [ ]" }
            let indent = String(repeating: " ", count: (ordered ? "\(start + index)." : "*").count + 1)
            let separator = item.attrs["spread"]?.boolValue == true ? "\n\n" : "\n"
            // An empty first paragraph leaves the marker on its own.
            let content = blocks(item).joined(separator: separator)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var text = lines.first.map { $0.isEmpty ? marker : marker + " " + $0 } ?? marker
            for line in lines.dropFirst() { text += "\n" + (line.isEmpty ? "" : indent + line) }
            items.append(text)
        }
        return items.joined(separator: list.attrs["spread"]?.boolValue == true ? "\n\n" : "\n")
    }

    /// Writes a GitHub table with cells padded to the column width, as `markdown-table` does.
    private func table(_ node: ButtermilkCore.Node) -> String {
        var rows: [[String]] = []
        var alignments: [String?] = []
        node.forEach { row, _, rowIndex in
            var cells: [String] = []
            row.forEach { cell, _, _ in
                var parts: [String] = []
                cell.forEach { block, _, _ in parts.append(inline(block, inTable: true)) }
                cells.append(parts.joined(separator: " "))
                // GitHub tables have no spans; covered columns get empty cells.
                let span = min(max(cell.attrs["colspan"]?.intValue ?? 1, 1), Tables.maxCellSpan)
                cells += Array(repeating: "", count: span - 1)
                if rowIndex == 0 { alignments += Array(repeating: cell.attrs["alignment"]?.stringValue, count: span) }
            }
            rows.append(cells)
        }
        let columns = rows.map(\.count).max() ?? 0
        alignments += Array(repeating: nil, count: max(0, columns - alignments.count))
        var widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        var delimiters: [String] = []
        for column in 0..<columns {
            let (before, after) = switch alignments[column] {
            case "left": (":", "")
            case "center": (":", ":")
            case "right": ("", ":")
            default: ("", "")
            }
            let dashes = max(1, widths[column] - before.count - after.count)
            delimiters.append(before + String(repeating: "-", count: dashes) + after)
            widths[column] = max(widths[column], delimiters[column].count)
        }
        func line(_ cells: [String], pad: Bool) -> String {
            let padded = (0..<columns).map { column -> String in
                let cell = column < cells.count ? cells[column] : ""
                guard pad else { return cell }
                let gap = widths[column] - cell.count
                switch alignments[column] {
                case "right": return String(repeating: " ", count: gap) + cell
                case "center":
                    return String(repeating: " ", count: (gap + 1) / 2) + cell + String(repeating: " ", count: gap / 2)
                default: return cell + String(repeating: " ", count: gap)
                }
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [line(rows.first ?? [], pad: true), line(delimiters, pad: false)]
        lines += rows.dropFirst().map { line($0, pad: true) }
        return lines.joined(separator: "\n")
    }

    // MARK: Inline content

    private struct Context {
        var inHeading = false
        var inTable = false
        var inLink = false
    }

    private func inline(_ parent: ButtermilkCore.Node, inHeading: Bool = false, inTable: Bool = false) -> String {
        var items: [(ButtermilkCore.Node, [Mark])] = []
        parent.forEach { child, _, _ in items.append((child, child.marks)) }
        var out = ""
        nest(items[...], Context(inHeading: inHeading, inTable: inTable), into: &out)
        return out
    }

    /// Turns inline content with flat mark sets into nested Markdown spans.
    private func nest(_ items: ArraySlice<(ButtermilkCore.Node, [Mark])>, _ context: Context, into out: inout String) {
        var i = items.startIndex
        while i < items.endIndex {
            let (node, marks) = items[i]
            // Code marks are written innermost, since inline code cannot contain markup.
            guard let outer = marks.first(where: { !$0.type.spec.code }) else {
                append(leaf(node, code: !marks.isEmpty, context, lineStart: out.isEmpty || out.hasSuffix("\n")), to: &out)
                i += 1
                continue
            }
            var j = i
            var run: [(ButtermilkCore.Node, [Mark])] = []
            while j < items.endIndex, items[j].1.contains(outer) {
                run.append((items[j].0, items[j].1.filter { $0 != outer }))
                j += 1
            }
            var inner = context
            if outer.type.name == "link" { inner.inLink = true }
            var content = ""
            nest(run[...], inner, into: &content)
            append(wrap(outer, content, lineStart: out.isEmpty || out.hasSuffix("\n")), to: &out)
            i = j
        }
    }

    /// Appends `piece`, escaping a `!` that would turn a following link into an image.
    private func append(_ piece: String, to out: inout String) {
        if piece.hasPrefix("["), out.hasSuffix("!"), !out.hasSuffix("\\!") { out.insert("\\", at: out.index(before: out.endIndex)) }
        out += piece
    }

    private func leaf(_ node: ButtermilkCore.Node, code: Bool, _ context: Context, lineStart: Bool) -> String {
        if let text = node.text {
            if code { return inlineCode(context.inTable ? text.replacingOccurrences(of: "|", with: "\\|") : text) }
            return escape(text, context, lineStart: lineStart)
        }
        switch node.type.name {
        case "hard_break", "hardbreak":
            return context.inHeading || context.inTable ? " " : "\\\n"
        case "image":
            let alt = escape(node.attrs["alt"]?.stringValue ?? "", Context(inLink: true), lineStart: false)
            return "![" + alt + "](" + destination(node.attrs["src"]?.stringValue ?? "", title: node.attrs["title"]?.stringValue) + ")"
        default:
            return escape(node.textContent, context, lineStart: lineStart)
        }
    }

    private func inlineCode(_ code: String) -> String {
        // Use the shortest backtick fence that does not occur in the code.
        var runs = Set<Int>(), run = 0
        for c in code + " " {
            if c == "`" { run += 1 } else if run > 0 { runs.insert(run); run = 0 }
        }
        var size = 1
        while runs.contains(size) { size += 1 }
        let fence = String(repeating: "`", count: size)
        let pad = code.hasPrefix("`") || code.hasSuffix("`") || (code.hasPrefix(" ") && code.hasSuffix(" ") && code.contains { $0 != " " })
        return fence + (pad ? " " + code + " " : code) + fence
    }

    /// Marks Markdown has no syntax for are dropped; their content stays.
    private func wrap(_ mark: Mark, _ content: String, lineStart: Bool) -> String {
        let delimiter: String
        switch mark.type.name {
        case "em", "emphasis": delimiter = "*"
        case "strong": delimiter = "**"
        case "strike_through", "strikethrough": delimiter = "~~"
        case "link":
            let href = mark.attrs["href"]?.stringValue ?? ""
            let title = mark.attrs["title"]?.stringValue
            if title == nil, content == href, href.range(of: "^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\\s<>]*$", options: .regularExpression) != nil {
                return "<" + href + ">"
            }
            return "[" + content + "](" + destination(href, title: title) + ")"
        default:
            return content
        }
        // Delimiters next to whitespace do not open or close a span, so whitespace moves outside.
        let leading = content.prefix { $0.isWhitespace }, trailing = content.reversed().prefix { $0.isWhitespace }
        guard leading.count < content.count else { return content }
        let core = content.dropFirst(leading.count).dropLast(trailing.count)
        return leading + delimiter + core + delimiter + String(trailing.reversed())
    }

    private func destination(_ url: String, title: String?) -> String {
        var out: String
        if url.isEmpty || url.contains(where: { $0 == " " || $0 == "<" || $0 == ">" || $0.isNewline }) {
            out = "<" + url.replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>") + ">"
        } else {
            out = url.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }
        if let title {
            out += " \"" + title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return out
    }

    /// Escapes characters that would otherwise start Markdown syntax.
    ///
    /// `lineStart` is true when the text starts a line, where block syntax such as `#` or `1.`
    /// can begin. `<` is not escaped, because raw HTML is kept as text and written back as is.
    private func escape(_ text: String, _ context: Context, lineStart: Bool) -> String {
        let chars = Array(text)
        var out = ""
        func isWord(_ i: Int) -> Bool { i >= 0 && i < chars.count && (chars[i].isLetter || chars[i].isNumber) }
        for (i, c) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var escaped: Bool
            switch c {
            case "*", "[", "`", "~": escaped = true
            case "_": escaped = !(isWord(i - 1) && isWord(i + 1))
            case "\\": escaped = next.map { $0.isASCII && $0.isPunctuation || $0.isASCII && $0.isSymbol } ?? true
            case "&": escaped = next.map { $0 == "#" || $0.isASCII && $0.isLetter } ?? false
            case "]": escaped = context.inLink
            case "|": escaped = context.inTable
            default: escaped = false
            }
            if lineStart, !escaped {
                let first = i == 0
                let afterSpace = next == nil || next == " " || next == "\t"
                switch c {
                case "#", ">", "=": escaped = first
                case "+": escaped = first && afterSpace
                case "-": escaped = first && (afterSpace || next == "-")
                case ".", ")":
                    escaped = i > 0 && chars[..<i].allSatisfy(\.isASCII) && chars[..<i].allSatisfy(\.isNumber) && afterSpace
                default: break
                }
            }
            if escaped { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
