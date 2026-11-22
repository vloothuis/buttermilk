/// A piece of a document: a fragment plus the open depth at its start and end.
public struct Slice: Equatable, CustomStringConvertible {
    public let content: Fragment
    public let openStart: Int
    public let openEnd: Int

    public init(_ content: Fragment, openStart: Int, openEnd: Int) {
        self.content = content
        self.openStart = openStart
        self.openEnd = openEnd
    }

    public static let empty = Slice(.empty, openStart: 0, openEnd: 0)

    public var size: Int { content.size - openStart - openEnd }

    public func insertAt(_ pos: Int, _ fragment: Fragment) -> Slice? {
        insertInto(content, pos + openStart, fragment, openStart + 1, openEnd + 1, nil)
            .map { Slice($0, openStart: openStart, openEnd: openEnd) }
    }

    public func removeBetween(_ from: Int, _ to: Int) throws -> Slice {
        Slice(try removeRange(content, from + openStart, to + openStart), openStart: openStart, openEnd: openEnd)
    }

    public func eq(_ other: Slice) -> Bool {
        content.eq(other.content) && openStart == other.openStart && openEnd == other.openEnd
    }

    public static func == (a: Slice, b: Slice) -> Bool { a.eq(b) }

    public var description: String { "\(content)(\(openStart),\(openEnd))" }

    public func toJSON() -> JSON? {
        guard content.size > 0 else { return nil }
        var json: [String: JSON] = ["content": content.toJSON() ?? .null]
        if openStart > 0 { json["openStart"] = .number(Double(openStart)) }
        if openEnd > 0 { json["openEnd"] = .number(Double(openEnd)) }
        return .object(json)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON?) throws -> Slice {
        guard let json, !json.isNull else { return .empty }
        let openStart = json["openStart"] ?? 0, openEnd = json["openEnd"] ?? 0
        guard let os = openStart.intValue, let oe = openEnd.intValue else {
            throw ProseError.range("Invalid input for Slice.fromJSON")
        }
        return Slice(try Fragment.fromJSON(schema, json["content"]), openStart: os, openEnd: oe)
    }

    /// Create a slice from a fragment by taking the maximum possible open value on both sides.
    public static func maxOpen(_ fragment: Fragment, openIsolating: Bool = true) -> Slice {
        var openStart = 0, openEnd = 0
        var n = fragment.firstChild
        while let c = n, !c.isLeaf, openIsolating || !c.type.spec.isolating { openStart += 1; n = c.firstChild }
        n = fragment.lastChild
        while let c = n, !c.isLeaf, openIsolating || !c.type.spec.isolating { openEnd += 1; n = c.lastChild }
        return Slice(fragment, openStart: openStart, openEnd: openEnd)
    }
}

private func removeRange(_ content: Fragment, _ from: Int, _ to: Int) throws -> Fragment {
    let (index, offset) = content.findIndex(from)
    let child = content.maybeChild(index)
    let (indexTo, offsetTo) = content.findIndex(to)
    if offset == from || child!.isText {
        if offsetTo != to && !content.child(indexTo).isText { throw ProseError.range("Removing non-flat range") }
        return content.cut(0, from).append(content.cut(to))
    }
    if index != indexTo { throw ProseError.range("Removing non-flat range") }
    return content.replaceChild(index, child!.copy(try removeRange(child!.content, from - offset - 1, to - offset - 1)))
}

private func insertInto(_ content: Fragment, _ dist: Int, _ insert: Fragment, _ openStart: Int, _ openEnd: Int,
                        _ parent: Node?) -> Fragment? {
    let (index, offset) = content.findIndex(dist)
    let child = content.maybeChild(index)
    if offset == dist || child!.isText {
        if let parent, openStart <= 0, openEnd <= 0, !parent.canReplace(index, index, insert) { return nil }
        return content.cut(0, dist).append(insert).append(content.cut(dist))
    }
    let inner = insertInto(child!.content, dist - offset - 1, insert, index == 0 ? openStart - 1 : 0,
                           index == content.childCount - 1 ? openEnd - 1 : 0, child)
    return inner.map { content.replaceChild(index, child!.copy($0)) }
}

func replace(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice) throws -> Node {
    if slice.openStart > from.depth { throw ProseError.replace("Inserted content deeper than insertion position") }
    if from.depth - slice.openStart != to.depth - slice.openEnd { throw ProseError.replace("Inconsistent open depths") }
    return try replaceOuter(from, to, slice, 0)
}

private func replaceOuter(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice, _ depth: Int) throws -> Node {
    let index = from.index(depth), node = from.node(depth)
    if index == to.index(depth) && depth < from.depth - slice.openStart {
        let inner = try replaceOuter(from, to, slice, depth + 1)
        return node.copy(node.content.replaceChild(index, inner))
    } else if slice.content.size == 0 {
        return try close(node, replaceTwoWay(from, to, depth))
    } else if slice.openStart == 0 && slice.openEnd == 0 && from.depth == depth && to.depth == depth {
        let parent = from.parent, content = parent.content
        return try close(parent, content.cut(0, from.parentOffset).append(slice.content).append(content.cut(to.parentOffset)))
    } else {
        let (start, end) = prepareSliceForReplace(slice, from)
        return try close(node, replaceThreeWay(from, start, end, to, depth))
    }
}

private func checkJoin(_ main: Node, _ sub: Node) throws {
    if !sub.type.compatibleContent(main.type) {
        throw ProseError.replace("Cannot join \(sub.type.name) onto \(main.type.name)")
    }
}

private func joinable(_ before: ResolvedPos, _ after: ResolvedPos, _ depth: Int) throws -> Node {
    let node = before.node(depth)
    try checkJoin(node, after.node(depth))
    return node
}

private func addNode(_ child: Node, _ target: inout [Node]) {
    if let last = target.last, child.isText, child.sameMarkup(last) {
        target[target.count - 1] = child.withText(last.text! + child.text!)
    } else {
        target.append(child)
    }
}

private func addRange(_ start: ResolvedPos?, _ end: ResolvedPos?, _ depth: Int, _ target: inout [Node]) {
    let node = (end ?? start)!.node(depth)
    var startIndex = 0
    let endIndex = end?.index(depth) ?? node.childCount
    if let start {
        startIndex = start.index(depth)
        if start.depth > depth {
            startIndex += 1
        } else if start.textOffset > 0 {
            addNode(start.nodeAfter!, &target)
            startIndex += 1
        }
    }
    var i = startIndex
    while i < endIndex { addNode(node.child(i), &target); i += 1 }
    if let end, end.depth == depth, end.textOffset > 0 { addNode(end.nodeBefore!, &target) }
}

private func close(_ node: Node, _ content: Fragment) throws -> Node {
    if !node.type.validContent(content) { throw ProseError.replace("Invalid content for node \(node.type.name)") }
    return node.copy(content)
}

private func replaceThreeWay(_ from: ResolvedPos, _ start: ResolvedPos, _ end: ResolvedPos, _ to: ResolvedPos,
                             _ depth: Int) throws -> Fragment {
    let openStart = from.depth > depth ? try joinable(from, start, depth + 1) : nil
    let openEnd = to.depth > depth ? try joinable(end, to, depth + 1) : nil
    var content: [Node] = []
    addRange(nil, from, depth, &content)
    if let openStart, let openEnd, start.index(depth) == end.index(depth) {
        try checkJoin(openStart, openEnd)
        addNode(try close(openStart, replaceThreeWay(from, start, end, to, depth + 1)), &content)
    } else {
        if let openStart { addNode(try close(openStart, replaceTwoWay(from, start, depth + 1)), &content) }
        addRange(start, end, depth, &content)
        if let openEnd { addNode(try close(openEnd, replaceTwoWay(end, to, depth + 1)), &content) }
    }
    addRange(to, nil, depth, &content)
    return Fragment(content)
}

private func replaceTwoWay(_ from: ResolvedPos, _ to: ResolvedPos, _ depth: Int) throws -> Fragment {
    var content: [Node] = []
    addRange(nil, from, depth, &content)
    if from.depth > depth {
        let type = try joinable(from, to, depth + 1)
        addNode(try close(type, replaceTwoWay(from, to, depth + 1)), &content)
    }
    addRange(to, nil, depth, &content)
    return Fragment(content)
}

private func prepareSliceForReplace(_ slice: Slice, _ along: ResolvedPos) -> (ResolvedPos, ResolvedPos) {
    let extra = along.depth - slice.openStart, parent = along.node(extra)
    var node = parent.copy(slice.content)
    var i = extra - 1
    while i >= 0 { node = along.node(i).copy(Fragment(node)); i -= 1 }
    return (node.resolveNoCache(slice.openStart + extra), node.resolveNoCache(node.content.size - slice.openEnd - extra))
}
