/// A node in a document tree. Nodes are immutable values with reference identity.
///
/// Text nodes have a non-nil ``text``. Positions and sizes are counted in UTF-16 code units,
/// matching ProseMirror and TextKit.
public final class Node: CustomStringConvertible {
    public let type: NodeType
    public let attrs: Attrs
    public let content: Fragment
    public let marks: [Mark]
    /// The text of a text node, `nil` for other nodes.
    public let text: String?
    private let textLength: Int
    private var resolveCache: [ResolvedPos] = []
    private var resolveCacheIndex = 0

    public init(type: NodeType, attrs: Attrs, content: Fragment = .empty, marks: [Mark] = []) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.text = nil
        self.textLength = 0
    }

    init(type: NodeType, attrs: Attrs, text: String, marks: [Mark]) {
        self.type = type
        self.attrs = attrs
        self.content = .empty
        self.marks = marks
        self.text = text
        self.textLength = text.utf16.count
    }

    public var children: [Node] { content.children }

    public var nodeSize: Int {
        if text != nil { return textLength }
        return isLeaf ? 1 : 2 + content.size
    }

    public var childCount: Int { content.childCount }
    public func child(_ index: Int) -> Node { content.child(index) }
    public func maybeChild(_ index: Int) -> Node? { content.maybeChild(index) }
    public func forEach(_ f: (Node, Int, Int) -> Void) { content.forEach(f) }

    /// Invoke `f` for all descendants between `from` and `to`. Return `false` to skip children.
    public func nodesBetween(_ from: Int, _ to: Int, startPos: Int = 0, _ f: (Node, Int, Node?, Int) -> Bool) {
        content.nodesBetween(from, to, nodeStart: startPos, parent: self, f)
    }

    public func descendants(_ f: (Node, Int, Node?, Int) -> Bool) {
        nodesBetween(0, content.size, f)
    }

    public var textContent: String {
        if let text { return text }
        if isLeaf, let lt = type.spec.leafText { return lt(self) }
        return textBetween(0, content.size, blockSeparator: "")
    }

    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil,
                            leafText: ((Node) -> String)? = nil) -> String {
        if let text { return text.utf16Slice(from, to) }
        return content.textBetween(from, to, blockSeparator: blockSeparator, leafText: leafText)
    }

    public var firstChild: Node? { content.firstChild }
    public var lastChild: Node? { content.lastChild }

    /// Structural equality.
    public func eq(_ other: Node) -> Bool {
        if self === other { return true }
        if text != nil || other.text != nil { return sameMarkup(other) && text == other.text }
        return sameMarkup(other) && content.eq(other.content)
    }

    public func sameMarkup(_ other: Node) -> Bool { hasMarkup(other.type, other.attrs, other.marks) }

    public func hasMarkup(_ type: NodeType, _ attrs: Attrs? = nil, _ marks: [Mark]? = nil) -> Bool {
        self.type === type && self.attrs == (attrs ?? type.defaultAttrs ?? [:]) && self.marks == (marks ?? [])
    }

    /// A new node with the same markup and the given content.
    public func copy(_ content: Fragment = .empty) -> Node {
        if text != nil { return self }
        return Node(type: type, attrs: attrs, content: content, marks: marks)
    }

    /// A copy of this node with the given marks.
    public func mark(_ marks: [Mark]) -> Node {
        if marks == self.marks { return self }
        if let text { return Node(type: type, attrs: attrs, text: text, marks: marks) }
        return Node(type: type, attrs: attrs, content: content, marks: marks)
    }

    func withText(_ text: String) -> Node {
        if text == self.text { return self }
        return Node(type: type, attrs: attrs, text: text, marks: marks)
    }

    public func cut(_ from: Int, _ to: Int? = nil) -> Node {
        if let text {
            let to = to ?? textLength
            if from == 0 && to == textLength { return self }
            return withText(text.utf16Slice(from, to))
        }
        let to = to ?? content.size
        if from == 0 && to == content.size { return self }
        return copy(content.cut(from, to))
    }

    public func slice(_ from: Int, _ to: Int? = nil, includeParents: Bool = false) -> Slice {
        let to = to ?? content.size
        if from == to { return .empty }
        let rFrom = resolve(from), rTo = resolve(to)
        let depth = includeParents ? 0 : rFrom.sharedDepth(to)
        let start = rFrom.start(depth), node = rFrom.node(depth)
        let content = node.content.cut(rFrom.pos - start, rTo.pos - start)
        return Slice(content, openStart: rFrom.depth - depth, openEnd: rTo.depth - depth)
    }

    /// Replace the range with a slice. Throws ``ProseError/replace(_:)`` when the result is invalid.
    public func replace(_ from: Int, _ to: Int, _ slice: Slice) throws -> Node {
        try ButtermilkCore.replace(resolve(from), resolve(to), slice)
    }

    public func nodeAt(_ pos: Int) -> Node? {
        var node: Node = self
        var pos = pos
        while true {
            let (index, offset) = node.content.findIndex(pos)
            guard let next = node.maybeChild(index) else { return nil }
            if offset == pos || next.isText { return next }
            pos -= offset + 1
            node = next
        }
    }

    public func childAfter(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        let (index, offset) = content.findIndex(pos)
        return (content.maybeChild(index), index, offset)
    }

    public func childBefore(_ pos: Int) -> (node: Node?, index: Int, offset: Int) {
        if pos == 0 { return (nil, 0, 0) }
        let (index, offset) = content.findIndex(pos)
        if offset < pos { return (content.child(index), index, offset) }
        let node = content.child(index - 1)
        return (node, index - 1, offset - node.nodeSize)
    }

    /// Resolve a position in this document. Results are cached.
    public func resolve(_ pos: Int) -> ResolvedPos {
        for r in resolveCache where r.pos == pos { return r }
        let result = ResolvedPos.resolve(self, pos)
        if resolveCache.count < 12 { resolveCache.append(result) } else { resolveCache[resolveCacheIndex] = result }
        resolveCacheIndex = (resolveCacheIndex + 1) % 12
        return result
    }

    public func resolveNoCache(_ pos: Int) -> ResolvedPos { ResolvedPos.resolve(self, pos) }

    public func rangeHasMark(_ from: Int, _ to: Int, _ type: MarkType) -> Bool {
        var found = false
        if to > from {
            nodesBetween(from, to) { node, _, _, _ in
                if type.isInSet(node.marks) != nil { found = true }
                return !found
            }
        }
        return found
    }

    public func rangeHasMark(_ from: Int, _ to: Int, _ mark: Mark) -> Bool {
        var found = false
        if to > from {
            nodesBetween(from, to) { node, _, _, _ in
                if mark.isInSet(node.marks) { found = true }
                return !found
            }
        }
        return found
    }

    public var isBlock: Bool { type.isBlock }
    public var isTextblock: Bool { type.isTextblock }
    public var inlineContent: Bool { type.inlineContent }
    public var isInline: Bool { type.isInline }
    public var isText: Bool { type.isText }
    public var isLeaf: Bool { type.isLeaf }
    public var isAtom: Bool { type.isAtom }

    public var description: String {
        if let d = type.spec.toDebugString { return d(self) }
        var name: String
        if let text {
            name = jsonQuote(text)
        } else {
            name = type.name
            if content.size > 0 { name += "(" + content.toStringInner() + ")" }
        }
        for m in marks.reversed() { name = m.type.name + "(" + name + ")" }
        return name
    }

    public func contentMatchAt(_ index: Int) -> ContentMatch {
        guard let match = type.contentMatch.matchFragment(content, start: 0, end: index) else {
            preconditionFailure("Called contentMatchAt on a node with invalid content")
        }
        return match
    }

    public func canReplace(_ from: Int, _ to: Int, _ replacement: Fragment = .empty, start: Int = 0, end: Int? = nil) -> Bool {
        let end = end ?? replacement.childCount
        guard let one = contentMatchAt(from).matchFragment(replacement, start: start, end: end),
              let two = one.matchFragment(content, start: to), two.validEnd else { return false }
        for i in start..<max(start, end) where !type.allowsMarks(replacement.child(i).marks) { return false }
        return true
    }

    public func canReplaceWith(_ from: Int, _ to: Int, _ type: NodeType, marks: [Mark]? = nil) -> Bool {
        if let marks, !self.type.allowsMarks(marks) { return false }
        guard let start = contentMatchAt(from).matchType(type),
              let end = start.matchFragment(content, start: to) else { return false }
        return end.validEnd
    }

    public func canAppend(_ other: Node) -> Bool {
        if other.content.size > 0 { return canReplace(childCount, childCount, other.content) }
        return type.compatibleContent(other.type)
    }

    /// Check that this node and its descendants conform to the schema.
    public func check() throws {
        try type.checkContent(content)
        try checkAttrs(type.attrs, attrs, "node", type.name)
        var copy: [Mark] = []
        for mark in marks {
            try checkAttrs(mark.type.attrs, mark.attrs, "mark", mark.type.name)
            copy = mark.addToSet(copy)
        }
        if copy != marks {
            throw ProseError.range("Invalid collection of marks for node \(type.name): \(marks.map(\.type.name))")
        }
        for child in content.children { try child.check() }
    }

    public func toJSON() -> JSON {
        var obj: [String: JSON] = ["type": .string(type.name)]
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        if content.size > 0, let c = content.toJSON() { obj["content"] = c }
        if !marks.isEmpty { obj["marks"] = .array(marks.map { $0.toJSON() }) }
        if let text { obj["text"] = .string(text) }
        return .object(obj)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Node {
        guard case .object = json, let typeName = json["type"]?.stringValue else {
            throw ProseError.range("Invalid input for Node.fromJSON")
        }
        var marks: [Mark] = []
        if let m = json["marks"], !m.isNull {
            guard let arr = m.arrayValue else { throw ProseError.range("Invalid mark data for Node.fromJSON") }
            marks = try arr.map(schema.markFromJSON)
        }
        if typeName == "text" {
            guard let text = json["text"]?.stringValue else { throw ProseError.range("Invalid text node in JSON") }
            if text.isEmpty { throw ProseError.range("Empty text nodes are not allowed") }
            return schema.text(text, marks: marks)
        }
        let content = try Fragment.fromJSON(schema, json["content"])
        return try schema.nodeType(typeName).create(json["attrs"]?.objectValue, content, marks: marks)
    }
}

func jsonQuote(_ s: String) -> String {
    JSON.string(s).serialized()
}
