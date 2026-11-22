import ButtermilkCore
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public extension NSAttributedString.Key {
    /// Marks text that does not belong to the document, such as list bullets.
    static let buttermilkMarker = NSAttributedString.Key("ButtermilkMarker")
}

/// One rendered top-level block. Positions and offsets in `map` are relative to the block.
struct RenderedBlock {
    let node: Node
    let text: NSAttributedString
    let map: BlockMap
}

/// A rendered document: attributed text plus the position map that links it to the document.
public struct RenderedDocument {
    var blocks: [RenderedBlock]
    public private(set) var map: PositionMap

    init(blocks: [RenderedBlock]) {
        self.blocks = blocks
        map = PositionMap(blocks: blocks.map(\.map), sizes: blocks.map(\.node.nodeSize), lengths: blocks.map(\.text.length))
    }

    /// The full text. Views apply ``TextChange``s instead of reading this after each edit.
    public var text: NSAttributedString {
        let out = NSMutableAttributedString()
        blocks.forEach { out.append($0.text) }
        return out
    }

    public var length: Int { blocks.last.map { map.blockOffset[blocks.count - 1] + $0.text.length } ?? 0 }

    func offset(ofBlock i: Int) -> Int { i < blocks.count ? map.blockOffset[i] : length }

    /// Replaces blocks `range` with `new`, updating the map from there on.
    mutating func replaceBlocks(_ range: Range<Int>, with new: [RenderedBlock]) {
        blocks.replaceSubrange(range, with: new)
        map.blocks.replaceSubrange(range, with: new.map(\.map))
        map.blockPos.replaceSubrange(range, with: new.map { _ in 0 })
        map.blockOffset.replaceSubrange(range, with: new.map { _ in 0 })
        var i = range.lowerBound
        var pos = i > 0 ? map.blockPos[i - 1] + blocks[i - 1].node.nodeSize : 0
        var offset = i > 0 ? map.blockOffset[i - 1] + blocks[i - 1].text.length : 0
        while i < blocks.count {
            // Past the new blocks, stop once the shift is known to be zero.
            if i >= range.lowerBound + new.count, map.blockPos[i] == pos, map.blockOffset[i] == offset { break }
            map.blockPos[i] = pos; map.blockOffset[i] = offset
            pos += blocks[i].node.nodeSize; offset += blocks[i].text.length
            i += 1
        }
    }
}

/// The part of the rendered text that changed between two renderings.
public struct TextChange {
    /// Range in the old text.
    public let range: NSRange
    /// Text that replaces it.
    public let replacement: NSAttributedString
}

/// Turns a document into attributed text for TextKit.
///
/// It knows the node and mark names of the basic, list and table schemas and of Milkdown's
/// CommonMark and GFM presets. Unknown textblocks render as paragraphs and unknown containers
/// render their children.
public struct DocumentRenderer {
    public var theme: Theme
    /// Loads the image for an image node's `src`. The default loads nothing, so documents
    /// cannot make the editor read files or reach the network; images show a placeholder.
    public var imageLoader: ((String) -> PlatformImage?)?
    /// URL schemes a link mark may open. Other links render styled but inactive.
    public var linkSchemes: Set<String> = ["http", "https", "mailto"]

    public init(theme: Theme = .standard, imageLoader: ((String) -> PlatformImage?)? = nil) {
        self.theme = theme; self.imageLoader = imageLoader
    }

    struct Context {
        var level = 0
        var marker: String?
        var heading: Int?
        var code = false
        var quote = 0
        var header = false
        #if canImport(AppKit)
        var textBlocks: [NSTextBlock] = []
        #endif
    }

    public func render(_ doc: Node) -> RenderedDocument {
        var blocks: [RenderedBlock] = []
        doc.forEach { child, _, _ in blocks.append(renderBlock(child)) }
        return RenderedDocument(blocks: blocks)
    }

    /// Renders `doc` again, reusing every top-level block that did not change. Nodes are
    /// immutable and transactions keep untouched nodes, so identity tells what changed.
    /// Returns the change to apply to text that showed `rendered` before.
    public func update(_ rendered: inout RenderedDocument, to doc: Node) -> TextChange {
        // Index into rendered.blocks directly: a copy would make the update below copy the array.
        let oldCount = rendered.blocks.count, count = doc.childCount
        var prefix = 0
        while prefix < min(oldCount, count), rendered.blocks[prefix].node === doc.child(prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(oldCount, count) - prefix,
              rendered.blocks[oldCount - 1 - suffix].node === doc.child(count - 1 - suffix) {
            suffix += 1
        }
        let middle = (prefix..<(count - suffix)).map { renderBlock(doc.child($0)) }
        let start = rendered.offset(ofBlock: prefix)
        let removed = rendered.offset(ofBlock: oldCount - suffix) - start
        let replacement = NSMutableAttributedString()
        middle.forEach { replacement.append($0.text) }
        rendered.replaceBlocks(prefix..<(oldCount - suffix), with: middle)
        return TextChange(range: NSRange(location: start, length: removed), replacement: replacement)
    }

    func renderBlock(_ node: Node) -> RenderedBlock {
        let state = RenderState(theme: theme, imageLoader: imageLoader, linkSchemes: linkSchemes)
        state.block(node, 0, Context())
        return RenderedBlock(node: node, text: state.out, map: state.map)
    }
}

private final class RenderState {
    let theme: Theme
    let out = NSMutableAttributedString()
    var map = BlockMap()

    let imageLoader: ((String) -> PlatformImage?)?
    let linkSchemes: Set<String>

    init(theme: Theme, imageLoader: ((String) -> PlatformImage?)?, linkSchemes: Set<String>) {
        self.theme = theme; self.imageLoader = imageLoader; self.linkSchemes = linkSchemes
    }

    func blocks(_ parent: Node, contentStart: Int, _ ctx: DocumentRenderer.Context) {
        var ctx = ctx
        parent.forEach { child, offset, index in
            let pos = contentStart + offset
            var childCtx = ctx
            if index > 0 { childCtx.marker = nil }
            block(child, pos, childCtx)
            ctx.marker = nil
        }
    }

    func block(_ node: Node, _ pos: Int, _ ctx: DocumentRenderer.Context) {
        var ctx = ctx
        let name = node.type.name
        if node.isTextblock {
            if name == "heading" { ctx.heading = node.attrs["level"]?.intValue ?? 1 }
            if node.type.spec.code { ctx.code = true }
            textblock(node, pos, ctx)
            return
        }
        if node.isLeaf {
            leafBlock(node, pos, ctx)
            return
        }
        switch node.type.tableRole {
        case "table":
            table(node, pos, ctx)
            return
        case "row":
            blocks(node, contentStart: pos + 1, ctx)
            return
        default: break
        }
        switch name {
        case "blockquote":
            ctx.level += 1
            ctx.quote += 1
            #if canImport(AppKit)
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(theme.secondaryColor.withAlphaComponent(0.4), for: .minX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            ctx.textBlocks.append(block)
            ctx.level -= 1
            #endif
            blocks(node, contentStart: pos + 1, ctx)
        case "bullet_list", "ordered_list":
            let start = node.attrs["order"]?.intValue ?? 1
            node.forEach { item, offset, index in
                var itemCtx = ctx
                itemCtx.level += 1
                if let checked = item.attrs["checked"]?.boolValue {
                    itemCtx.marker = checked ? "☑" : "☐"
                } else {
                    itemCtx.marker = name == "ordered_list" ? "\(start + index)." : (ctx.level % 2 == 0 ? "•" : "◦")
                }
                blocks(item, contentStart: pos + 1 + offset + 1, itemCtx)
            }
        default:
            blocks(node, contentStart: pos + 1, ctx)
        }
    }

    // MARK: Paragraphs

    func paragraphStyle(_ ctx: DocumentRenderer.Context) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        let indent = theme.indent * CGFloat(ctx.level)
        ps.headIndent = indent
        ps.firstLineHeadIndent = ctx.marker == nil ? indent : max(indent - theme.indent, 0)
        ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        ps.paragraphSpacing = theme.blockSpacing
        ps.lineHeightMultiple = theme.lineHeightMultiple
        if let level = ctx.heading, level <= 2 { ps.paragraphSpacingBefore = theme.blockSpacing }
        #if canImport(AppKit)
        ps.textBlocks = ctx.textBlocks
        #endif
        return ps
    }

    func baseFont(_ ctx: DocumentRenderer.Context) -> PlatformFont {
        if ctx.code { return theme.codeFont }
        if let level = ctx.heading {
            let scale = theme.headingScale[min(max(level, 1), 6) - 1]
            return theme.font.with(bold: true, size: theme.font.pointSize * scale)
        }
        return ctx.header ? theme.font.with(bold: true) : theme.font
    }

    func baseAttributes(_ ctx: DocumentRenderer.Context) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont(ctx),
            .foregroundColor: ctx.quote > 0 ? theme.secondaryColor : theme.textColor,
            .paragraphStyle: paragraphStyle(ctx),
        ]
        if ctx.code {
            #if canImport(AppKit)
            if ctx.textBlocks.isEmpty { attrs[.backgroundColor] = theme.codeBackground }
            #else
            attrs[.backgroundColor] = theme.codeBackground
            #endif
        }
        return attrs
    }

    func textblock(_ node: Node, _ pos: Int, _ ctx: DocumentRenderer.Context) {
        var ctx = ctx
        #if canImport(AppKit)
        if ctx.code {
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.backgroundColor = theme.codeBackground
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            ctx.textBlocks.append(block)
        }
        #endif
        let base = baseAttributes(ctx)
        if let marker = ctx.marker {
            var markerAttrs = base
            markerAttrs[.foregroundColor] = theme.secondaryColor
            markerAttrs[.buttermilkMarker] = true
            out.append(NSAttributedString(string: marker + "\t", attributes: markerAttrs))
        }
        let start = out.length
        inline(node, base)
        precondition(out.length - start == node.content.size, "inline rendering must map one to one")
        map.segments.append(.init(pos: pos + 1, offset: start, length: node.content.size))
        out.append(NSAttributedString(string: "\n", attributes: base))
    }

    func inline(_ parent: Node, _ base: [NSAttributedString.Key: Any]) {
        parent.forEach { child, _, _ in
            var attrs = base
            for mark in child.marks { apply(mark, to: &attrs) }
            if let text = child.text {
                out.append(NSAttributedString(string: text, attributes: attrs))
            } else if child.type.name == "hard_break" || child.type.name == "hardbreak" {
                out.append(NSAttributedString(string: "\u{2028}", attributes: attrs))
            } else if child.isLeaf {
                out.append(attachment(for: child, attrs))
            } else {
                // Inline nodes with content: a zero-width character stands in for each token.
                out.append(NSAttributedString(string: "\u{200B}", attributes: attrs))
                inline(child, attrs)
                out.append(NSAttributedString(string: "\u{200B}", attributes: attrs))
            }
        }
    }

    func apply(_ mark: Mark, to attrs: inout [NSAttributedString.Key: Any]) {
        let font = attrs[.font] as? PlatformFont ?? theme.font
        switch mark.type.name {
        case "strong":
            attrs[.font] = font.with(bold: true, italic: font.isItalic)
        case "em", "emphasis":
            attrs[.font] = font.with(bold: font.isBold, italic: true)
        case "code", "inlineCode", "code_inline":
            attrs[.font] = theme.codeFont
            attrs[.backgroundColor] = theme.codeBackground
        case "link":
            attrs[.foregroundColor] = theme.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let href = mark.attrs["href"]?.stringValue, let url = URL(string: href),
               let scheme = url.scheme?.lowercased(), linkSchemes.contains(scheme) {
                attrs[.link] = url
            }
        case "strike_through", "strikethrough", "strike":
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        default:
            break
        }
    }

    // MARK: Leaves

    func attachment(for node: Node, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let font = attrs[.font] as? PlatformFont ?? theme.font
        if node.type.name == "image", let src = node.attrs["src"]?.stringValue, let image = imageLoader?(src) {
            attachment.image = image
            let maxWidth: CGFloat = 480
            let scale = min(1, maxWidth / max(image.size.width, 1))
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        } else {
            let side = font.pointSize
            attachment.image = Self.placeholder(CGSize(width: side, height: side), theme.secondaryColor)
            attachment.bounds = CGRect(x: 0, y: font.descender, width: side, height: side)
        }
        var a = attrs
        a[.attachment] = attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: a)
    }

    func leafBlock(_ node: Node, _ pos: Int, _ ctx: DocumentRenderer.Context) {
        let base = baseAttributes(ctx)
        let attachment = NSTextAttachment()
        if node.type.name == "image", let src = node.attrs["src"]?.stringValue, let image = imageLoader?(src) {
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
        } else {
            // Horizontal rules and unknown leaf blocks: a thin rule.
            attachment.image = Self.rule(width: 560, color: theme.secondaryColor.withAlphaComponent(0.5))
            attachment.bounds = CGRect(x: 0, y: 4, width: 560, height: 1)
        }
        var attrs = base
        attrs[.attachment] = attachment
        map.atoms.append(.init(pos: pos, offset: out.length))
        out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
        out.append(NSAttributedString(string: "\n", attributes: base))
    }

    // MARK: Tables

    func table(_ node: Node, _ pos: Int, _ ctx: DocumentRenderer.Context) {
        let map = TableMap.get(node)
        #if canImport(AppKit)
        let table = NSTextTable()
        table.numberOfColumns = max(map.width, 1)
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        var rowPos = pos + 1
        for row in 0..<node.childCount {
            let rowNode = node.child(row)
            rowNode.forEach { cell, offset, _ in
                let cellPos = rowPos + 1 + offset
                let rect = map.problems == nil ? map.findCell(cellPos - pos - 1) : TableRect(left: 0, top: row, right: 1, bottom: row + 1)
                let block = NSTextTableBlock(table: table, startingRow: rect.top, rowSpan: rect.bottom - rect.top,
                                             startingColumn: rect.left, columnSpan: rect.right - rect.left)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(theme.secondaryColor.withAlphaComponent(0.5))
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if cell.type.tableRole == "header_cell" { block.backgroundColor = theme.codeBackground }
                var cellCtx = DocumentRenderer.Context()
                cellCtx.textBlocks = ctx.textBlocks + [block]
                cellCtx.header = cell.type.tableRole == "header_cell"
                cellCtx.quote = ctx.quote
                blocks(cell, contentStart: cellPos + 1, cellCtx)
            }
            rowPos += rowNode.nodeSize
        }
        #else
        // UIKit has no text tables: cells render as indented blocks, one row after another.
        var rowPos = pos + 1
        for row in 0..<node.childCount {
            let rowNode = node.child(row)
            rowNode.forEach { cell, offset, index in
                var cellCtx = ctx
                cellCtx.level += 1
                cellCtx.marker = index == 0 ? "▸" : "│"
                cellCtx.header = cell.type.tableRole == "header_cell"
                blocks(cell, contentStart: rowPos + 1 + offset + 1, cellCtx)
            }
            rowPos += rowNode.nodeSize
        }
        _ = map
        #endif
    }

    // MARK: Images

    static func placeholder(_ size: CGSize, _ color: PlatformColor) -> PlatformImage {
        draw(size) { rect in
            color.withAlphaComponent(0.25).setFill()
            #if canImport(AppKit)
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            #else
            UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3).fill()
            #endif
        }
    }

    static func rule(width: CGFloat, color: PlatformColor) -> PlatformImage {
        draw(CGSize(width: width, height: 1)) { rect in
            color.setFill()
            #if canImport(AppKit)
            rect.fill()
            #else
            UIRectFill(rect)
            #endif
        }
    }

    static func draw(_ size: CGSize, _ body: @escaping (CGRect) -> Void) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(size: size, flipped: false) { rect in body(rect); return true }
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in body(CGRect(origin: .zero, size: size)) }
        #endif
    }
}
