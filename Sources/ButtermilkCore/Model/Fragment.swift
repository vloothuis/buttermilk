import Foundation

extension String {
    /// Length in UTF-16 code units, the unit ProseMirror positions count in.
    @inlinable var utf16Length: Int { utf16.count }

    /// Slice by UTF-16 offsets.
    func utf16Slice(_ from: Int, _ to: Int? = nil) -> String {
        let u = utf16
        let to = Swift.min(to ?? u.count, u.count)
        let from = Swift.max(0, Swift.min(from, to))
        if from == 0 && to == u.count { return self }
        let s = u.index(u.startIndex, offsetBy: from), e = u.index(u.startIndex, offsetBy: to)
        if let str = String(u[s..<e]) { return str }
        return String(utf16CodeUnits: Array(u[s..<e]), count: to - from)
    }
}

/// A fragment represents a node's collection of child nodes.
public struct Fragment: Equatable, CustomStringConvertible, Sequence {
    public let children: [Node]
    public let size: Int

    public init(_ children: [Node], size: Int? = nil) {
        self.children = children
        self.size = size ?? children.reduce(0) { $0 + $1.nodeSize }
    }

    public init(_ node: Node) { self.init([node], size: node.nodeSize) }

    public static let empty = Fragment([], size: 0)

    public func makeIterator() -> IndexingIterator<[Node]> { children.makeIterator() }

    /// Invoke a callback for all descendant nodes between `from` and `to`.
    /// Return `false` from the callback to skip a node's children.
    public func nodesBetween(_ from: Int, _ to: Int, nodeStart: Int = 0, parent: Node? = nil,
                             _ f: (Node, Int, Node?, Int) -> Bool) {
        var pos = 0, i = 0
        while pos < to {
            let child = children[i], end = pos + child.nodeSize
            if end > from && f(child, nodeStart + pos, parent, i) && child.content.size > 0 {
                let start = pos + 1
                child.nodesBetween(Swift.max(0, from - start), Swift.min(child.content.size, to - start),
                                   startPos: nodeStart + start, f)
            }
            pos = end
            i += 1
        }
    }

    public func descendants(_ f: (Node, Int, Node?, Int) -> Bool) {
        nodesBetween(0, size, f)
    }

    public func textBetween(_ from: Int, _ to: Int, blockSeparator: String? = nil,
                            leafText: ((Node) -> String)? = nil) -> String {
        var text = "", first = true
        nodesBetween(from, to) { node, pos, _, _ in
            let nodeText: String
            if let t = node.text {
                nodeText = t.utf16Slice(Swift.max(from, pos) - pos, to - pos)
            } else if !node.isLeaf {
                nodeText = ""
            } else if let leafText {
                nodeText = leafText(node)
            } else if let lt = node.type.spec.leafText {
                nodeText = lt(node)
            } else {
                nodeText = ""
            }
            if node.isBlock && (node.isLeaf && !nodeText.isEmpty || node.isTextblock), let sep = blockSeparator {
                if first { first = false } else { text += sep }
            }
            text += nodeText
            return true
        }
        return text
    }

    public func append(_ other: Fragment) -> Fragment {
        if other.size == 0 { return self }
        if size == 0 { return other }
        let last = lastChild!, first = other.firstChild!
        var content = children
        var i = 0
        if last.isText && last.sameMarkup(first) {
            content[content.count - 1] = last.withText(last.text! + first.text!)
            i = 1
        }
        content.append(contentsOf: other.children[i...])
        return Fragment(content, size: size + other.size)
    }

    public func cut(_ from: Int, _ to: Int? = nil) -> Fragment {
        let to = to ?? size
        if from == 0 && to == size { return self }
        var result: [Node] = []
        var rsize = 0
        if to > from {
            var pos = 0, i = 0
            while pos < to {
                var child = children[i]
                let end = pos + child.nodeSize
                if end > from {
                    if pos < from || end > to {
                        if child.isText {
                            child = child.cut(Swift.max(0, from - pos), Swift.min(child.text!.utf16Length, to - pos))
                        } else {
                            child = child.cut(Swift.max(0, from - pos - 1), Swift.min(child.content.size, to - pos - 1))
                        }
                    }
                    result.append(child)
                    rsize += child.nodeSize
                }
                pos = end
                i += 1
            }
        }
        return Fragment(result, size: rsize)
    }

    public func cutByIndex(_ from: Int, _ to: Int) -> Fragment {
        if from == to { return .empty }
        if from == 0 && to == children.count { return self }
        return Fragment(Array(children[from..<to]))
    }

    public func replaceChild(_ index: Int, _ node: Node) -> Fragment {
        let current = children[index]
        if current === node { return self }
        var copy = children
        copy[index] = node
        return Fragment(copy, size: size + node.nodeSize - current.nodeSize)
    }

    public func addToStart(_ node: Node) -> Fragment { Fragment([node] + children, size: size + node.nodeSize) }
    public func addToEnd(_ node: Node) -> Fragment { Fragment(children + [node], size: size + node.nodeSize) }

    public func eq(_ other: Fragment) -> Bool {
        children.count == other.children.count && zip(children, other.children).allSatisfy { $0.eq($1) }
    }

    public static func == (a: Fragment, b: Fragment) -> Bool { a.eq(b) }

    public var firstChild: Node? { children.first }
    public var lastChild: Node? { children.last }
    public var childCount: Int { children.count }

    public func child(_ index: Int) -> Node {
        precondition(index >= 0 && index < children.count, "Index \(index) out of range for \(self)")
        return children[index]
    }

    public func maybeChild(_ index: Int) -> Node? {
        index >= 0 && index < children.count ? children[index] : nil
    }

    public func forEach(_ f: (Node, Int, Int) -> Void) {
        var p = 0
        for (i, child) in children.enumerated() {
            f(child, p, i)
            p += child.nodeSize
        }
    }

    public func findDiffStart(_ other: Fragment, pos: Int = 0) -> Int? {
        ButtermilkCore.findDiffStart(self, other, pos)
    }

    public func findDiffEnd(_ other: Fragment, pos: Int? = nil, otherPos: Int? = nil) -> (a: Int, b: Int)? {
        ButtermilkCore.findDiffEnd(self, other, pos ?? size, otherPos ?? other.size)
    }

    /// Find the index and inner offset corresponding to a given relative position.
    public func findIndex(_ pos: Int) -> (index: Int, offset: Int) {
        if pos == 0 { return (0, pos) }
        if pos == size { return (children.count, pos) }
        precondition(pos > 0 && pos < size, "Position \(pos) outside of fragment (\(self))")
        var curPos = 0, i = 0
        while true {
            let cur = child(i), end = curPos + cur.nodeSize
            if end >= pos {
                if end == pos { return (i + 1, end) }
                return (i, curPos)
            }
            curPos = end
            i += 1
        }
    }

    public var description: String { "<" + toStringInner() + ">" }
    func toStringInner() -> String { children.map(\.description).joined(separator: ", ") }

    public func toJSON() -> JSON? {
        children.isEmpty ? nil : .array(children.map { $0.toJSON() })
    }

    public static func fromJSON(_ schema: Schema, _ value: JSON?) throws -> Fragment {
        guard let value, !value.isNull else { return .empty }
        guard let arr = value.arrayValue else { throw ProseError.range("Invalid input for Fragment.fromJSON") }
        return fromArray(try arr.map(schema.nodeFromJSON))
    }

    /// Build a fragment from an array of nodes, joining adjacent text nodes with the same marks.
    public static func fromArray(_ array: [Node]) -> Fragment {
        if array.isEmpty { return .empty }
        var joined: [Node]?
        var size = 0
        for (i, node) in array.enumerated() {
            size += node.nodeSize
            if i > 0 && node.isText && array[i - 1].sameMarkup(node) {
                if joined == nil { joined = Array(array[0..<i]) }
                joined![joined!.count - 1] = node.withText(joined![joined!.count - 1].text! + node.text!)
            } else if joined != nil {
                joined!.append(node)
            }
        }
        return Fragment(joined ?? array, size: size)
    }

    public static func from(_ nodes: [Node]) -> Fragment { fromArray(nodes) }
    public static func from(_ node: Node?) -> Fragment { node.map { Fragment($0) } ?? .empty }
}

func findDiffStart(_ a: Fragment, _ b: Fragment, _ pos: Int) -> Int? {
    var pos = pos
    var i = 0
    while true {
        if i == a.childCount || i == b.childCount { return a.childCount == b.childCount ? nil : pos }
        let childA = a.child(i), childB = b.child(i)
        if childA === childB { pos += childA.nodeSize; i += 1; continue }
        if !childA.sameMarkup(childB) { return pos }
        if childA.isText && childA.text != childB.text {
            let tA = Array(childA.text!.utf16), tB = Array(childB.text!.utf16)
            var j = 0
            while j < tA.count && j < tB.count && tA[j] == tB[j] { j += 1; pos += 1 }
            if j > 0 && j < tA.count && j < tB.count && isSurrogateHigh(tA[j - 1]) && isSurrogateLow(tA[j]) { pos -= 1 }
            return pos
        }
        if childA.content.size > 0 || childB.content.size > 0 {
            if let inner = findDiffStart(childA.content, childB.content, pos + 1) { return inner }
        }
        pos += childA.nodeSize
        i += 1
    }
}

func findDiffEnd(_ a: Fragment, _ b: Fragment, _ posA: Int, _ posB: Int) -> (a: Int, b: Int)? {
    var posA = posA, posB = posB
    var iA = a.childCount, iB = b.childCount
    while true {
        if iA == 0 || iB == 0 { return iA == iB ? nil : (posA, posB) }
        iA -= 1; iB -= 1
        let childA = a.child(iA), childB = b.child(iB), size = childA.nodeSize
        if childA === childB { posA -= size; posB -= size; continue }
        if !childA.sameMarkup(childB) { return (posA, posB) }
        if childA.isText && childA.text != childB.text {
            let tA = Array(childA.text!.utf16), tB = Array(childB.text!.utf16)
            var ia = tA.count, ib = tB.count
            while ia > 0 && ib > 0 && tA[ia - 1] == tB[ib - 1] { ia -= 1; ib -= 1; posA -= 1; posB -= 1 }
            if ia > 0 && ib > 0 && ia < tA.count && isSurrogateHigh(tA[ia - 1]) && isSurrogateLow(tA[ia]) {
                posA += 1; posB += 1
            }
            return (posA, posB)
        }
        if childA.content.size > 0 || childB.content.size > 0 {
            if let inner = findDiffEnd(childA.content, childB.content, posA - 1, posB - 1) { return inner }
        }
        posA -= size; posB -= size
    }
}

@inline(__always) func isSurrogateLow(_ ch: UInt16) -> Bool { ch >= 0xDC00 && ch < 0xE000 }
@inline(__always) func isSurrogateHigh(_ ch: UInt16) -> Bool { ch >= 0xD800 && ch < 0xDC00 }
