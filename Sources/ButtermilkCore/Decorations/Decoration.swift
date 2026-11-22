import Foundation

/// Text attributes a decoration adds to the rendered text.
public typealias DecorationAttributes = [NSAttributedString.Key: Any]

/// Styling or extra content that the view shows over the document without changing it, as in
/// `prosemirror-view`.
///
/// - An inline decoration adds attributes to the text in `from..<to`.
/// - A node decoration adds attributes to all text of the node that starts at `from` and ends at `to`.
/// - A widget decoration inserts text at `from` (which equals `to`). The text belongs to no
///   document position, so the cursor skips over it.
///
/// Decorations keep their ``kind`` when mapped, so two decorations are equal when they cover the
/// same range and share the same kind object.
public struct Decoration {
    public final class Kind {
        public enum Variant {
            case inline(inclusiveStart: Bool, inclusiveEnd: Bool)
            case node
            case widget(NSAttributedString, side: Int)
        }
        public let variant: Variant
        public let attributes: DecorationAttributes
        /// Free-form data, as `spec` in ProseMirror. `spec["key"]` is not used for equality here.
        public let spec: [String: Any]
        init(_ variant: Variant, _ attributes: DecorationAttributes, _ spec: [String: Any]) {
            self.variant = variant; self.attributes = attributes; self.spec = spec
        }
    }

    public let from: Int
    public let to: Int
    public let kind: Kind

    public var attributes: DecorationAttributes { kind.attributes }
    public var spec: [String: Any] { kind.spec }

    public var isInline: Bool { if case .inline = kind.variant { return true }; return false }
    public var isNode: Bool { if case .node = kind.variant { return true }; return false }
    public var isWidget: Bool { if case .widget = kind.variant { return true }; return false }

    /// The widget's side: negative widgets sit before the cursor at their position, others after.
    public var side: Int { if case .widget(_, let side) = kind.variant { return side }; return 0 }
    public var widget: NSAttributedString? { if case .widget(let text, _) = kind.variant { return text }; return nil }

    init(from: Int, to: Int, kind: Kind) { self.from = from; self.to = to; self.kind = kind }

    /// Inline decoration. `inclusiveStart` and `inclusiveEnd` decide whether text inserted at the
    /// edges is covered after mapping.
    public static func inline(_ from: Int, _ to: Int, _ attributes: DecorationAttributes,
                              inclusiveStart: Bool = false, inclusiveEnd: Bool = false,
                              spec: [String: Any] = [:]) -> Decoration {
        Decoration(from: from, to: to, kind: Kind(.inline(inclusiveStart: inclusiveStart, inclusiveEnd: inclusiveEnd), attributes, spec))
    }

    /// Node decoration for the node from `from` to `to`.
    public static func node(_ from: Int, _ to: Int, _ attributes: DecorationAttributes, spec: [String: Any] = [:]) -> Decoration {
        Decoration(from: from, to: to, kind: Kind(.node, attributes, spec))
    }

    /// Widget decoration showing `text` at `pos`. Missing attributes come from the text around it.
    public static func widget(_ pos: Int, _ text: NSAttributedString, side: Int = 0, spec: [String: Any] = [:]) -> Decoration {
        Decoration(from: pos, to: pos, kind: Kind(.widget(text, side: side), [:], spec))
    }

    public static func widget(_ pos: Int, _ text: String, _ attributes: DecorationAttributes = [:], side: Int = 0,
                              spec: [String: Any] = [:]) -> Decoration {
        widget(pos, NSAttributedString(string: text, attributes: attributes), side: side, spec: spec)
    }

    /// A copy covering `from..<to`, keeping the kind.
    public init(clipping deco: Decoration, from: Int, to: Int) { self.init(from: from, to: to, kind: deco.kind) }

    /// The decoration moved by `offset`, keeping its kind.
    public func shifted(by offset: Int) -> Decoration { Decoration(from: from + offset, to: to + offset, kind: kind) }

    /// Maps the decoration through `mapping`. Returns nil when it no longer applies: an inline
    /// decoration that became empty, a node decoration whose node was replaced, or a widget
    /// whose position was deleted.
    public func map(_ mapping: Mappable, _ doc: Node? = nil) -> Decoration? {
        switch kind.variant {
        case .inline(let inclusiveStart, let inclusiveEnd):
            let f = mapping.map(from, assoc: inclusiveStart ? -1 : 1)
            let t = mapping.map(to, assoc: inclusiveEnd ? 1 : -1)
            return f < t ? Decoration(from: f, to: t, kind: kind) : nil
        case .node:
            let f = mapping.mapResult(from, assoc: 1), t = mapping.mapResult(to, assoc: -1)
            guard !f.deleted, !t.deleted, f.pos < t.pos else { return nil }
            if let doc {
                guard t.pos <= doc.content.size, let node = doc.nodeAt(f.pos), node.nodeSize == t.pos - f.pos else { return nil }
            }
            return Decoration(from: f.pos, to: t.pos, kind: kind)
        case .widget(_, let side):
            let r = mapping.mapResult(from, assoc: side < 0 ? -1 : 1)
            return r.deleted ? nil : Decoration(from: r.pos, to: r.pos, kind: kind)
        }
    }
}

extension Decoration: Equatable {
    public static func == (a: Decoration, b: Decoration) -> Bool { a.from == b.from && a.to == b.to && a.kind === b.kind }
}

/// A sorted, immutable collection of decorations, as `DecorationSet` in `prosemirror-view`.
/// Plugins usually keep one in their state, map it in `apply`, and return it from the
/// ``EditorProps/decorations`` prop.
public struct DecorationSet {
    /// Sorted by `from`, then `to`.
    public let all: [Decoration]

    public static let empty = DecorationSet(sorted: [])

    init(sorted: [Decoration]) { all = sorted }

    public var isEmpty: Bool { all.isEmpty }

    /// Creates a set. The document is used to drop decorations outside it.
    public static func create(_ doc: Node, _ decorations: [Decoration]) -> DecorationSet {
        let size = doc.content.size
        return DecorationSet(sorted: sort(decorations.filter { $0.from >= 0 && $0.to <= size && $0.from <= $0.to }))
    }

    static func sort(_ decorations: [Decoration]) -> [Decoration] {
        decorations.enumerated().sorted {
            ($0.element.from, $0.element.to, $0.offset) < ($1.element.from, $1.element.to, $1.offset)
        }.map(\.element)
    }

    /// Decorations that touch `start...end`, optionally filtered by spec.
    public func find(_ start: Int? = nil, _ end: Int? = nil, _ predicate: (([String: Any]) -> Bool)? = nil) -> [Decoration] {
        let start = start ?? 0, end = end ?? Int.max
        var out: [Decoration] = []
        for deco in all {
            if deco.from > end { break }
            if deco.to >= start, predicate?(deco.spec) ?? true { out.append(deco) }
        }
        return out
    }

    /// Maps the set through a transaction's mapping.
    public func map(_ mapping: Mappable, _ doc: Node) -> DecorationSet {
        guard !all.isEmpty else { return self }
        return DecorationSet(sorted: Self.sort(all.compactMap { $0.map(mapping, doc) }))
    }

    public func add(_ doc: Node, _ decorations: [Decoration]) -> DecorationSet {
        decorations.isEmpty ? self : Self.create(doc, all + decorations)
    }

    /// Removes the given decorations (compared with `==`).
    public func remove(_ decorations: [Decoration]) -> DecorationSet {
        decorations.isEmpty ? self : DecorationSet(sorted: all.filter { !decorations.contains($0) })
    }
}
