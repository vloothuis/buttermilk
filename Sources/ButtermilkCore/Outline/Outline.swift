import Foundation

/// A heading in a document outline.
public struct OutlineHeading: Equatable {
    /// The heading level, from the `level` attribute clamped to 1...6 (1 when missing).
    public let level: Int
    public let text: String
    /// The position directly before the heading node.
    public let pos: Int
    /// The position directly after the heading node.
    public let end: Int
    /// Index of the heading among the document's top-level children.
    public let index: Int
}

/// A heading with the headings nested under it.
public struct OutlineEntry: Equatable {
    public let heading: OutlineHeading
    public let children: [OutlineEntry]
}

/// A heading's section: the heading and the blocks after it, up to the next heading of the same
/// or a higher level (a lower or equal level number) or the end of the document.
public struct OutlineSection: Equatable {
    public let heading: OutlineHeading
    /// The headings that contain this section, outermost first.
    public let ancestors: [OutlineHeading]
    /// The section starts at ``OutlineHeading/pos``.
    public var from: Int { heading.pos }
    public let to: Int
}

/// Document outlines built from headings. Only top-level headings count: a heading inside a
/// list item, blockquote or table cell does not open a section, because a section is a run of
/// top-level blocks. Text before the first heading belongs to no section.
public enum Outline {
    /// The top-level headings of `doc` in document order. `type` is the heading node type name.
    public static func headings(_ doc: Node, type: String = "heading") -> [OutlineHeading] {
        var out: [OutlineHeading] = []
        var index = 0
        doc.forEach { node, offset, _ in
            if node.type.name == type {
                out.append(OutlineHeading(level: max(1, min(node.attrs["level"]?.intValue ?? 1, 6)), text: node.textContent,
                                          pos: offset, end: offset + node.nodeSize, index: index))
            }
            index += 1
        }
        return out
    }

    /// The headings as a tree. A heading becomes a child of the nearest earlier heading with a
    /// lower level; skipped levels (an h3 right after an h1) nest directly.
    public static func tree(_ doc: Node, type: String = "heading") -> [OutlineEntry] {
        let list = headings(doc, type: type)
        var i = 0
        func build(_ parentLevel: Int) -> [OutlineEntry] {
            var entries: [OutlineEntry] = []
            while i < list.count, list[i].level > parentLevel {
                let h = list[i]; i += 1
                entries.append(OutlineEntry(heading: h, children: build(h.level)))
            }
            return entries
        }
        return build(Int.min)
    }

    /// The section of `heading`.
    public static func section(_ doc: Node, of heading: OutlineHeading, type: String = "heading") -> OutlineSection {
        let list = headings(doc, type: type)
        let next = list.first { $0.pos > heading.pos && $0.level <= heading.level }
        var ancestors: [OutlineHeading] = []
        for h in list where h.pos < heading.pos {
            while let last = ancestors.last, last.level >= h.level { ancestors.removeLast() }
            ancestors.append(h)
        }
        while let last = ancestors.last, last.level >= heading.level { ancestors.removeLast() }
        return OutlineSection(heading: heading, ancestors: ancestors, to: next?.pos ?? doc.content.size)
    }

    /// The innermost section containing `pos`, or nil before the first heading. A position
    /// directly before a heading belongs to that heading's section.
    public static func section(_ doc: Node, at pos: Int, type: String = "heading") -> OutlineSection? {
        guard let owner = headings(doc, type: type).last(where: { $0.pos <= pos }) else { return nil }
        return section(doc, of: owner, type: type)
    }

    /// Selects the section around the selection head, heading included.
    public static func selectSection(type: String = "heading") -> Command {
        { state, dispatch, _ in
            guard let s = section(state.doc, at: state.selection.head, type: type) else { return false }
            dispatch?(state.tr.setSelection(TextSelection.between(state.doc.resolve(s.from), state.doc.resolve(s.to)))
                .scrollIntoView())
            return true
        }
    }

    /// Puts the cursor at the start of the next (or, with `forward` false, previous) heading.
    public static func moveToHeading(forward: Bool = true, type: String = "heading") -> Command {
        { state, dispatch, _ in
            let head = state.selection.head, list = headings(state.doc, type: type)
            guard let target = forward ? list.first(where: { $0.pos + 1 > head })
                                       : list.last(where: { $0.pos + 1 < head }) else { return false }
            dispatch?(state.tr.setSelection(TextSelection.create(state.doc, target.pos + 1)).scrollIntoView())
            return true
        }
    }
}
