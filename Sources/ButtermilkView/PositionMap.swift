import ButtermilkCore

/// The position map of one top-level block, in coordinates relative to the block.
///
/// Inline content of a textblock maps one to one: text keeps its UTF-16 length, and inline leaf
/// nodes (images, hard breaks) render as one character. Each textblock is one ``Segment``, or
/// several when widget decorations split it. Widget text belongs to no position.
/// Leaf blocks such as horizontal rules render as one attachment character (an ``Atom``).
/// Everything else in the text (list markers, block separators) belongs to no position.
/// Segments and atoms are sorted both by position and by offset.
public struct BlockMap {
    public struct Segment {
        /// Document position where the textblock content starts.
        public let pos: Int
        /// Text offset where the content starts.
        public let offset: Int
        /// Content size; the same in both coordinate systems.
        public let length: Int
        var endPos: Int { pos + length }
        var endOffset: Int { offset + length }
    }

    public struct Atom {
        /// Document position before the leaf block.
        public let pos: Int
        /// Text offset of its attachment character.
        public let offset: Int
    }

    public internal(set) var segments: [Segment] = []
    public internal(set) var atoms: [Atom] = []

    /// The offset for `pos` if it is in a textblock or before an atom.
    func exactOffset(_ pos: Int) -> Int? {
        let a = partition(atoms) { $0.pos >= pos }
        if a < atoms.count, atoms[a].pos == pos { return atoms[a].offset }
        let i = partition(segments) { $0.endPos >= pos }
        if i < segments.count, segments[i].pos <= pos { return segments[i].offset + pos - segments[i].pos }
        return nil
    }

    /// The position for `offset` if it is in a textblock or on an atom.
    func exactPosition(_ offset: Int) -> Int? {
        let a = partition(atoms) { $0.offset >= offset }
        if a < atoms.count, atoms[a].offset == offset { return atoms[a].pos }
        let i = partition(segments) { $0.endOffset >= offset }
        if i < segments.count, segments[i].offset <= offset { return segments[i].pos + offset - segments[i].offset }
        return nil
    }

    /// The last segment that ends at or before `pos` (`byOffset`: offset), or the first that
    /// starts after it.
    func neighbour(_ value: Int, byOffset: Bool, before: Bool) -> Segment? {
        if before {
            let i = partition(segments) { (byOffset ? $0.endOffset : $0.endPos) > value }
            return i > 0 ? segments[i - 1] : nil
        }
        let i = partition(segments) { (byOffset ? $0.offset : $0.pos) > value }
        return i < segments.count ? segments[i] : nil
    }
}

/// Index of the first element for which `isAfter` is true (elements must be partitioned).
func partition<T>(_ items: [T], _ isAfter: (T) -> Bool) -> Int {
    var lo = 0, hi = items.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if isAfter(items[mid]) { hi = mid } else { lo = mid + 1 }
    }
    return lo
}

/// Maps between document positions and offsets (UTF-16) in the rendered text.
///
/// It is a list of ``BlockMap``s, one per top-level block, with the position and offset where
/// each block starts. An edit only re-renders the blocks it touched; the rest are shared.
public struct PositionMap {
    public typealias Segment = BlockMap.Segment
    public typealias Atom = BlockMap.Atom

    var blocks: [BlockMap] = []
    var blockPos: [Int] = []
    var blockOffset: [Int] = []

    init() {}

    init(blocks: [BlockMap], sizes: [Int], lengths: [Int]) {
        self.blocks = blocks
        blockPos.reserveCapacity(blocks.count)
        blockOffset.reserveCapacity(blocks.count)
        var pos = 0, offset = 0
        for i in blocks.indices {
            blockPos.append(pos); blockOffset.append(offset)
            pos += sizes[i]; offset += lengths[i]
        }
    }

    /// All segments in document coordinates. This walks the whole map.
    public var segments: [Segment] {
        blocks.indices.flatMap { i in
            blocks[i].segments.map { Segment(pos: $0.pos + blockPos[i], offset: $0.offset + blockOffset[i], length: $0.length) }
        }
    }

    /// All atoms in document coordinates. This walks the whole map.
    public var atoms: [Atom] {
        blocks.indices.flatMap { i in blocks[i].atoms.map { Atom(pos: $0.pos + blockPos[i], offset: $0.offset + blockOffset[i]) } }
    }

    private func block(atPos pos: Int) -> Int { max(partition(blockPos) { $0 > pos } - 1, 0) }
    private func block(atOffset offset: Int) -> Int { max(partition(blockOffset) { $0 > offset } - 1, 0) }

    /// The nearest segment before or after `value`, searching from block `start` outward.
    private func nearest(_ value: Int, from start: Int, byOffset: Bool, before: Bool) -> Segment? {
        var i = start
        while i >= 0 && i < blocks.count {
            let base = byOffset ? blockOffset[i] : blockPos[i]
            if let seg = blocks[i].neighbour(value - base, byOffset: byOffset, before: before) {
                return Segment(pos: seg.pos + blockPos[i], offset: seg.offset + blockOffset[i], length: seg.length)
            }
            i += before ? -1 : 1
        }
        return nil
    }

    /// The text offset for document position `pos`. Positions between blocks go to the nearest
    /// text in direction `bias` (1 forward, -1 backward).
    public func offset(for pos: Int, bias: Int = 1) -> Int {
        guard !blocks.isEmpty else { return 0 }
        let i = block(atPos: pos)
        if let o = blocks[i].exactOffset(pos - blockPos[i]) { return o + blockOffset[i] }
        if bias < 0, let seg = nearest(pos, from: i, byOffset: false, before: true) { return seg.endOffset }
        if let seg = nearest(pos, from: i, byOffset: false, before: false) { return seg.offset }
        return nearest(pos, from: i, byOffset: false, before: true)?.endOffset ?? 0
    }

    /// The document position for text offset `offset`. Offsets outside any textblock (markers,
    /// separators) go to the nearest textblock in direction `bias`.
    public func position(for offset: Int, bias: Int = 1) -> Int {
        guard !blocks.isEmpty else { return 0 }
        let i = block(atOffset: offset)
        if let p = blocks[i].exactPosition(offset - blockOffset[i]) { return p + blockPos[i] }
        if bias < 0, let seg = nearest(offset, from: i, byOffset: true, before: true) { return seg.endPos }
        if let seg = nearest(offset, from: i, byOffset: true, before: false) { return seg.pos }
        return nearest(offset, from: i, byOffset: true, before: true)?.endPos ?? 0
    }

    /// Whether `offset` is inside or at the edge of a textblock.
    public func isInText(_ offset: Int) -> Bool {
        guard !blocks.isEmpty else { return false }
        let i = block(atOffset: offset), local = offset - blockOffset[i]
        let segs = blocks[i].segments
        let j = partition(segs) { $0.endOffset >= local }
        return j < segs.count && segs[j].offset <= local
    }

    /// The atom at text offset `offset`, if any.
    public func atom(at offset: Int) -> Atom? {
        guard !blocks.isEmpty else { return nil }
        let i = block(atOffset: offset), local = offset - blockOffset[i]
        let atoms = blocks[i].atoms
        let a = partition(atoms) { $0.offset >= local }
        guard a < atoms.count, atoms[a].offset == local else { return nil }
        return Atom(pos: atoms[a].pos + blockPos[i], offset: offset)
    }
}
