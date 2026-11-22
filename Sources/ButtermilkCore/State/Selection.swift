/// A range in a selection. Most selections have exactly one.
public struct SelectionRange {
    public let from: ResolvedPos
    public let to: ResolvedPos
    public init(_ from: ResolvedPos, _ to: ResolvedPos) { self.from = from; self.to = to }
}

/// A stored selection that can be mapped through changes without access to a document.
public protocol SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark
    func resolve(_ doc: Node) -> Selection
}

/// The base class for selections. Subclass it for custom selection types (for example a gap cursor).
open class Selection: CustomStringConvertible {
    public let resolvedAnchor: ResolvedPos
    public let resolvedHead: ResolvedPos
    public let ranges: [SelectionRange]

    public init(_ anchor: ResolvedPos, _ head: ResolvedPos, ranges: [SelectionRange]? = nil) {
        resolvedAnchor = anchor
        resolvedHead = head
        self.ranges = ranges ?? [SelectionRange(anchor.min(head), anchor.max(head))]
    }

    public var anchor: Int { resolvedAnchor.pos }
    public var head: Int { resolvedHead.pos }
    public var from: Int { resolvedFrom.pos }
    public var to: Int { resolvedTo.pos }
    public var resolvedFrom: ResolvedPos { ranges[0].from }
    public var resolvedTo: ResolvedPos { ranges[0].to }
    /// True when all ranges are empty.
    public var isEmpty: Bool { ranges.allSatisfy { $0.from.pos == $0.to.pos } }
    /// Whether the view should draw this selection as a native selection.
    open var visible: Bool { true }
    /// The JSON `type` identifier of this selection class.
    open class var jsonID: String { fatalError("Selection subclasses must override jsonID") }

    open func eq(_ other: Selection) -> Bool { fatalError("Selection subclasses must override eq") }
    open func map(_ doc: Node, _ mapping: Mappable) -> Selection { fatalError("Selection subclasses must override map") }
    open func toJSON() -> JSON { fatalError("Selection subclasses must override toJSON") }

    /// The selected content as a slice.
    open func content() -> Slice { resolvedFrom.doc.slice(from, to, includeParents: true) }

    /// Replace the selection with a slice. `nil` means delete the selection.
    open func replace(_ tr: Transaction, _ content: Slice? = nil) throws {
        let slice = content ?? .empty
        var lastNode = slice.content.lastChild
        var lastParent: Node?
        for _ in 0..<slice.openEnd {
            lastParent = lastNode
            lastNode = lastNode?.lastChild
        }
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            try tr.replaceRange(mapping.map(range.from.pos), mapping.map(range.to.pos), i > 0 ? .empty : slice)
            if i == 0 {
                let inline = lastNode.map { $0.isInline } ?? (lastParent?.isTextblock ?? false)
                selectionToInsertionEnd(tr, mapFrom, inline ? -1 : 1)
            }
        }
    }

    /// Replace the selection with a node.
    open func replaceWith(_ tr: Transaction, _ node: Node) throws {
        let mapFrom = tr.steps.count
        for (i, range) in ranges.enumerated() {
            let mapping = tr.mapping.slice(mapFrom)
            let from = mapping.map(range.from.pos), to = mapping.map(range.to.pos)
            if i > 0 {
                try tr.deleteRange(from, to)
            } else {
                try tr.replaceRangeWith(from, to, node)
                selectionToInsertionEnd(tr, mapFrom, node.isInline ? -1 : 1)
            }
        }
    }

    open func getBookmark() -> SelectionBookmark {
        TextSelection.between(resolvedAnchor, resolvedHead).getBookmark()
    }

    public var description: String { toJSON().description }

    // MARK: Finding selections

    /// Find a valid cursor or leaf node selection from `pos`, searching in direction `dir`.
    public static func findFrom(_ pos: ResolvedPos, _ dir: Int, textOnly: Bool = false) -> Selection? {
        if pos.parent.inlineContent { return TextSelection(pos) }
        if let inner = findSelectionIn(pos.doc, pos.parent, pos.pos, pos.index(), dir, textOnly) { return inner }
        var depth = pos.depth - 1
        while depth >= 0 {
            let found = dir < 0
                ? findSelectionIn(pos.doc, pos.node(depth), pos.before(depth + 1), pos.index(depth), dir, textOnly)
                : findSelectionIn(pos.doc, pos.node(depth), pos.after(depth + 1), pos.index(depth) + 1, dir, textOnly)
            if let found { return found }
            depth -= 1
        }
        return nil
    }

    /// Find a selection near `pos`, preferring direction `bias`. Falls back to selecting the whole document.
    public static func near(_ pos: ResolvedPos, bias: Int = 1) -> Selection {
        findFrom(pos, bias) ?? findFrom(pos, -bias) ?? AllSelection(pos.doc)
    }

    public static func atStart(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, 0, 0, 1) ?? AllSelection(doc)
    }

    public static func atEnd(_ doc: Node) -> Selection {
        findSelectionIn(doc, doc, doc.content.size, doc.childCount, -1) ?? AllSelection(doc)
    }

    // MARK: JSON

    public typealias Decoder = (Node, JSON) throws -> Selection
    nonisolated(unsafe) private static var decoders: [String: Decoder] = [
        "text": TextSelection.decode, "node": NodeSelection.decode, "all": { doc, _ in AllSelection(doc) },
    ]

    /// Register a selection type for ``fromJSON(_:_:)``.
    public static func register(_ id: String, _ decoder: @escaping Decoder) {
        precondition(decoders[id] == nil, "Duplicate use of selection JSON ID \(id)")
        decoders[id] = decoder
    }

    public static func fromJSON(_ doc: Node, _ json: JSON) throws -> Selection {
        guard let type = json["type"]?.stringValue else { throw ProseError.range("Invalid input for Selection.fromJSON") }
        guard let d = decoders[type] else { throw ProseError.range("No selection type \(type) defined") }
        return try d(doc, json)
    }
}

func checkedPosition(_ doc: Node, _ json: JSON?) throws -> Int {
    guard let p = json?.intValue, p >= 0, p <= doc.content.size else {
        throw ProseError.range("Invalid position in selection JSON")
    }
    return p
}

// MARK: - TextSelection

/// A text selection: a cursor or a range between two positions in inline content.
public final class TextSelection: Selection {
    public override class var jsonID: String { "text" }

    public init(_ anchor: ResolvedPos, _ head: ResolvedPos? = nil) {
        super.init(anchor, head ?? anchor)
    }

    /// The resolved position of the cursor when the selection is empty, otherwise nil.
    public var cursor: ResolvedPos? { anchor == head ? resolvedHead : nil }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let head = doc.resolve(mapping.map(self.head))
        if !head.parent.inlineContent { return Selection.near(head) }
        let anchor = doc.resolve(mapping.map(self.anchor))
        return TextSelection(anchor.parent.inlineContent ? anchor : head, head)
    }

    public override func replace(_ tr: Transaction, _ content: Slice? = nil) throws {
        try super.replace(tr, content)
        if content == nil, let marks = resolvedFrom.marksAcross(resolvedTo) { tr.ensureMarks(marks) }
    }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? TextSelection else { return false }
        return o.anchor == anchor && o.head == head
    }

    public override func getBookmark() -> SelectionBookmark { TextBookmark(anchor: anchor, head: head) }

    public override func toJSON() -> JSON { ["type": "text", "anchor": .number(Double(anchor)), "head": .number(Double(head))] }

    static func decode(_ doc: Node, _ json: JSON) throws -> Selection {
        TextSelection(doc.resolve(try checkedPosition(doc, json["anchor"])), doc.resolve(try checkedPosition(doc, json["head"])))
    }

    public static func create(_ doc: Node, _ anchor: Int, _ head: Int? = nil) -> TextSelection {
        let a = doc.resolve(anchor)
        return TextSelection(a, head == nil || head == anchor ? a : doc.resolve(head!))
    }

    /// Create a text selection between two positions, moving endpoints into inline content when needed.
    public static func between(_ anchor: ResolvedPos, _ head: ResolvedPos, bias: Int? = nil) -> Selection {
        var anchor = anchor, head = head
        let dPos = anchor.pos - head.pos
        var bias = bias ?? 0
        if bias == 0 || dPos != 0 { bias = dPos >= 0 ? 1 : -1 }
        if !head.parent.inlineContent {
            if let found = Selection.findFrom(head, bias, textOnly: true) ?? Selection.findFrom(head, -bias, textOnly: true) {
                head = found.resolvedHead
            } else {
                return Selection.near(head, bias: bias)
            }
        }
        if !anchor.parent.inlineContent {
            if dPos == 0 {
                anchor = head
            } else {
                anchor = (Selection.findFrom(anchor, -bias, textOnly: true) ?? Selection.findFrom(anchor, bias, textOnly: true))!.resolvedAnchor
                if (anchor.pos < head.pos) != (dPos < 0) { anchor = head }
            }
        }
        return TextSelection(anchor, head)
    }
}

struct TextBookmark: SelectionBookmark {
    let anchor: Int, head: Int
    func map(_ mapping: Mappable) -> SelectionBookmark { TextBookmark(anchor: mapping.map(anchor), head: mapping.map(head)) }
    func resolve(_ doc: Node) -> Selection { TextSelection.between(doc.resolve(anchor), doc.resolve(head)) }
}

// MARK: - NodeSelection

/// A selection of a single node.
public final class NodeSelection: Selection {
    public override class var jsonID: String { "node" }
    /// The selected node.
    public let node: Node

    /// Select the node after `pos`. The position must point before a node.
    public init(_ pos: ResolvedPos) {
        guard let node = pos.nodeAfter else { preconditionFailure("NodeSelection needs a node after its position") }
        self.node = node
        super.init(pos, pos.doc.resolve(pos.pos + node.nodeSize))
    }

    public override var visible: Bool { false }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let r = mapping.mapResult(anchor, assoc: 1)
        let pos = doc.resolve(r.pos)
        if r.deleted || pos.nodeAfter == nil { return Selection.near(pos) }
        return NodeSelection(pos)
    }

    public override func content() -> Slice { Slice(Fragment(node), openStart: 0, openEnd: 0) }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? NodeSelection else { return false }
        return o.anchor == anchor
    }

    public override func toJSON() -> JSON { ["type": "node", "anchor": .number(Double(anchor))] }

    public override func getBookmark() -> SelectionBookmark { NodeBookmark(anchor: anchor) }

    static func decode(_ doc: Node, _ json: JSON) throws -> Selection {
        let pos = doc.resolve(try checkedPosition(doc, json["anchor"]))
        guard pos.nodeAfter != nil else { throw ProseError.range("Invalid input for NodeSelection.fromJSON") }
        return NodeSelection(pos)
    }

    public static func create(_ doc: Node, _ from: Int) -> NodeSelection { NodeSelection(doc.resolve(from)) }

    /// Whether a node can be the target of a node selection.
    public static func isSelectable(_ node: Node) -> Bool { !node.isText && node.type.spec.selectable != false }
}

struct NodeBookmark: SelectionBookmark {
    let anchor: Int
    func map(_ mapping: Mappable) -> SelectionBookmark {
        let r = mapping.mapResult(anchor, assoc: 1)
        return r.deleted ? TextBookmark(anchor: r.pos, head: r.pos) : NodeBookmark(anchor: r.pos)
    }
    func resolve(_ doc: Node) -> Selection {
        let pos = doc.resolve(anchor)
        if let node = pos.nodeAfter, NodeSelection.isSelectable(node) { return NodeSelection(pos) }
        return Selection.near(pos)
    }
}

// MARK: - AllSelection

/// A selection that covers the whole document.
public final class AllSelection: Selection {
    public override class var jsonID: String { "all" }

    public init(_ doc: Node) { super.init(doc.resolve(0), doc.resolve(doc.content.size)) }

    public override func replace(_ tr: Transaction, _ content: Slice? = nil) throws {
        if let content {
            try super.replace(tr, content)
        } else {
            try tr.delete(0, tr.doc.content.size)
            let sel = Selection.atStart(tr.doc)
            if !sel.eq(tr.selection) { tr.setSelection(sel) }
        }
    }

    public override func toJSON() -> JSON { ["type": "all"] }
    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection { AllSelection(doc) }
    public override func eq(_ other: Selection) -> Bool { other is AllSelection }
    public override func getBookmark() -> SelectionBookmark { AllBookmark() }
}

struct AllBookmark: SelectionBookmark {
    func map(_ mapping: Mappable) -> SelectionBookmark { self }
    func resolve(_ doc: Node) -> Selection { AllSelection(doc) }
}

// MARK: - Helpers

func findSelectionIn(_ doc: Node, _ node: Node, _ pos: Int, _ index: Int, _ dir: Int, _ text: Bool = false) -> Selection? {
    if node.inlineContent { return TextSelection.create(doc, pos) }
    var pos = pos
    var i = index - (dir > 0 ? 0 : 1)
    while dir > 0 ? i < node.childCount : i >= 0 {
        let child = node.child(i)
        if !child.isAtom {
            if let inner = findSelectionIn(doc, child, pos + dir, dir < 0 ? child.childCount : 0, dir, text) { return inner }
        } else if !text && NodeSelection.isSelectable(child) {
            return NodeSelection.create(doc, pos - (dir < 0 ? child.nodeSize : 0))
        }
        pos += child.nodeSize * dir
        i += dir
    }
    return nil
}

func selectionToInsertionEnd(_ tr: Transaction, _ startLen: Int, _ bias: Int) {
    let last = tr.steps.count - 1
    if last < startLen { return }
    let step = tr.steps[last]
    guard step is ReplaceStep || step is ReplaceAroundStep else { return }
    var end: Int?
    tr.mapping.maps[last].forEach { _, _, _, newTo in if end == nil { end = newTo } }
    tr.setSelection(Selection.near(tr.doc.resolve(end!), bias: bias))
}
