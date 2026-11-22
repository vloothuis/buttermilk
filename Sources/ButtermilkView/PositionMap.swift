import ButtermilkCore

/// Maps between document positions and offsets (UTF-16) in the rendered text.
///
/// Inline content of a textblock maps one to one: text keeps its UTF-16 length, and inline leaf
/// nodes (images, hard breaks) render as one character. Each textblock is one ``Segment``.
/// Leaf blocks such as horizontal rules render as one attachment character (an ``Atom``).
/// Everything else in the text (list markers, block separators) belongs to no position.
public struct PositionMap {
    public struct Segment {
        /// Document position where the textblock content starts.
        public let pos: Int
        /// Text offset where the content starts.
        public let offset: Int
        /// Content size; the same in both coordinate systems.
        public let length: Int
    }

    public struct Atom {
        /// Document position before the leaf block.
        public let pos: Int
        /// Text offset of its attachment character.
        public let offset: Int
    }

    public internal(set) var segments: [Segment] = []
    public internal(set) var atoms: [Atom] = []

    /// The text offset for document position `pos`. Positions between blocks go to the nearest
    /// text in direction `bias` (1 forward, -1 backward).
    public func offset(for pos: Int, bias: Int = 1) -> Int {
        if let atom = atoms.first(where: { $0.pos == pos }) { return atom.offset }
        if let seg = segment(containing: pos) { return seg.offset + pos - seg.pos }
        if bias < 0, let seg = segments.last(where: { $0.pos + $0.length <= pos }) { return seg.offset + seg.length }
        if let seg = segments.first(where: { $0.pos >= pos }) { return seg.offset }
        if let seg = segments.last { return seg.offset + seg.length }
        return 0
    }

    /// The document position for text offset `offset`. Offsets outside any textblock (markers,
    /// separators) go to the nearest textblock in direction `bias`.
    public func position(for offset: Int, bias: Int = 1) -> Int {
        if let atom = atoms.first(where: { $0.offset == offset }) { return atom.pos }
        if let seg = segments.first(where: { offset >= $0.offset && offset <= $0.offset + $0.length }) {
            return seg.pos + offset - seg.offset
        }
        if bias < 0, let seg = segments.last(where: { $0.offset + $0.length < offset }) { return seg.pos + seg.length }
        if let seg = segments.first(where: { $0.offset > offset }) { return seg.pos }
        if let seg = segments.last { return seg.pos + seg.length }
        return 0
    }

    /// Whether `offset` is inside or at the edge of a textblock.
    public func isInText(_ offset: Int) -> Bool {
        segments.contains { offset >= $0.offset && offset <= $0.offset + $0.length }
    }

    func segment(containing pos: Int) -> Segment? {
        // Binary search: segments are sorted by position.
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, seg = segments[mid]
            if pos < seg.pos { hi = mid - 1 } else if pos > seg.pos + seg.length { lo = mid + 1 } else { return seg }
        }
        return nil
    }
}
