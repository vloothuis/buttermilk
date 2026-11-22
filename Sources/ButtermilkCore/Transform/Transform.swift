/// A failed transform step. Corresponds to ProseMirror's `TransformError`.
public struct TransformError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A node type plus optional attributes, used by wrapping and splitting.
public struct NodeTypeAttrs {
    public let type: NodeType
    public let attrs: Attrs?
    public init(_ type: NodeType, _ attrs: Attrs? = nil) { self.type = type; self.attrs = attrs }
}

/// An abstraction for building up and tracking an array of steps that change a document.
open class Transform {
    public private(set) var steps: [Step] = []
    public private(set) var docs: [Node] = []
    public let mapping = Mapping()
    /// The current document: the result of applying all steps.
    public internal(set) var doc: Node

    public init(_ doc: Node) { self.doc = doc }

    /// The starting document.
    public var before: Node { docs.first ?? doc }

    public var docChanged: Bool { !steps.isEmpty }

    /// Apply a step. Throws ``TransformError`` when it fails.
    @discardableResult
    public func step(_ step: Step) throws -> Self {
        let result = maybeStep(step)
        if let f = result.failed { throw TransformError(message: f) }
        return self
    }

    /// Try to apply a step, returning the result without throwing.
    @discardableResult
    public func maybeStep(_ step: Step) -> StepResult {
        let result = step.apply(doc)
        if result.failed == nil { addStep(step, result.doc!) }
        return result
    }

    open func addStep(_ step: Step, _ doc: Node) {
        docs.append(self.doc)
        steps.append(step)
        mapping.appendMap(step.getMap())
        self.doc = doc
    }

    /// The range of the document touched by the steps so far, in the current document.
    public func changedRange() -> (from: Int, to: Int)? {
        var from = Int(1e9), to = Int(-1e9)
        for (i, map) in mapping.maps.enumerated() {
            if i > 0 {
                from = map.map(from, assoc: 1)
                to = map.map(to, assoc: -1)
            }
            map.forEach { _, _, fromB, toB in
                from = min(from, fromB)
                to = max(to, toB)
            }
        }
        return from == Int(1e9) ? nil : (from, to)
    }

    // MARK: Replacing

    @discardableResult
    public func replace(_ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) throws -> Self {
        if let step = replaceStep(doc, from, to ?? from, slice) { try self.step(step) }
        return self
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ content: Fragment) throws -> Self {
        try replace(from, to, Slice(content, openStart: 0, openEnd: 0))
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ node: Node) throws -> Self {
        try replaceWith(from, to, Fragment(node))
    }

    @discardableResult
    public func replaceWith(_ from: Int, _ to: Int, _ nodes: [Node]) throws -> Self {
        try replaceWith(from, to, Fragment.from(nodes))
    }

    @discardableResult
    public func delete(_ from: Int, _ to: Int) throws -> Self { try replace(from, to, .empty) }

    @discardableResult
    public func insert(_ pos: Int, _ content: Fragment) throws -> Self { try replaceWith(pos, pos, content) }

    @discardableResult
    public func insert(_ pos: Int, _ node: Node) throws -> Self { try replaceWith(pos, pos, node) }

    @discardableResult
    public func insert(_ pos: Int, _ nodes: [Node]) throws -> Self { try replaceWith(pos, pos, nodes) }

    @discardableResult
    public func replaceRange(_ from: Int, _ to: Int, _ slice: Slice) throws -> Self {
        try ButtermilkCore.replaceRange(self, from, to, slice)
        return self
    }

    @discardableResult
    public func replaceRangeWith(_ from: Int, _ to: Int, _ node: Node) throws -> Self {
        var from = from, to = to
        if !node.isInline && from == to && doc.resolve(from).parent.content.size > 0,
           let point = insertPoint(doc, from, node.type) {
            from = point; to = point
        }
        return try replaceRange(from, to, Slice(Fragment(node), openStart: 0, openEnd: 0))
    }

    @discardableResult
    public func deleteRange(_ from: Int, _ to: Int) throws -> Self {
        try ButtermilkCore.deleteRange(self, from, to)
        return self
    }

    // MARK: Structure

    @discardableResult
    public func lift(_ range: NodeRange, _ target: Int) throws -> Self {
        let from = range.from, to = range.to, depth = range.depth
        let gapStart = from.before(depth + 1), gapEnd = to.after(depth + 1)
        var start = gapStart, end = gapEnd
        var before = Fragment.empty, openStart = 0
        var splitting = false
        var d = depth
        while d > target {
            if splitting || from.index(d) > 0 {
                splitting = true
                before = Fragment(from.node(d).copy(before))
                openStart += 1
            } else {
                start -= 1
            }
            d -= 1
        }
        var after = Fragment.empty, openEnd = 0
        splitting = false
        d = depth
        while d > target {
            if splitting || to.after(d + 1) < to.end(d) {
                splitting = true
                after = Fragment(to.node(d).copy(after))
                openEnd += 1
            } else {
                end += 1
            }
            d -= 1
        }
        return try step(ReplaceAroundStep(start, end, gapStart, gapEnd,
                                          Slice(before.append(after), openStart: openStart, openEnd: openEnd),
                                          before.size - openStart, structure: true))
    }

    @discardableResult
    public func join(_ pos: Int, depth: Int = 1) throws -> Self {
        var convertNewlines: Bool?
        let linebreak = doc.type.schema.linebreakReplacement
        let rBefore = doc.resolve(pos - depth), beforeType = rBefore.node().type
        if let linebreak, beforeType.inlineContent {
            let pre = beforeType.whitespace == .pre
            let supportLinebreak = beforeType.contentMatch.matchType(linebreak) != nil
            if pre && !supportLinebreak { convertNewlines = false }
            else if !pre && supportLinebreak { convertNewlines = true }
        }
        let mapFrom = steps.count
        if convertNewlines == false {
            let rAfter = doc.resolve(pos + depth)
            try replaceLinebreaks(rAfter.node(), rAfter.before(), mapFrom)
        }
        if beforeType.inlineContent {
            try clearIncompatible(pos + depth - 1, beforeType, match: rBefore.node().contentMatchAt(rBefore.index()),
                                  clearNewlines: convertNewlines == nil)
        }
        let m = mapping.slice(mapFrom), start = m.map(pos - depth)
        try step(ReplaceStep(start, m.map(pos + depth, assoc: -1), .empty, structure: true))
        if convertNewlines == true {
            let full = doc.resolve(start)
            try replaceNewlines(full.node(), full.before(), steps.count)
        }
        return self
    }

    @discardableResult
    public func wrap(_ range: NodeRange, _ wrappers: [NodeTypeAttrs]) throws -> Self {
        var content = Fragment.empty
        for w in wrappers.reversed() {
            if content.size > 0 {
                guard let match = w.type.contentMatch.matchFragment(content), match.validEnd else {
                    throw ProseError.range("Wrapper type given to Transform.wrap does not form valid content of its parent wrapper")
                }
            }
            content = Fragment(try w.type.create(w.attrs, content))
        }
        let start = range.start, end = range.end
        return try step(ReplaceAroundStep(start, end, start, end, Slice(content, openStart: 0, openEnd: 0),
                                          wrappers.count, structure: true))
    }

    @discardableResult
    public func setBlockType(_ from: Int, _ to: Int? = nil, _ type: NodeType, attrs: Attrs? = nil) throws -> Self {
        try setBlockType(from, to, type) { _ in attrs }
    }

    @discardableResult
    public func setBlockType(_ from: Int, _ to: Int? = nil, _ type: NodeType, attrs: (Node) -> Attrs?) throws -> Self {
        guard type.isTextblock else { throw ProseError.range("Type given to setBlockType should be a textblock") }
        let mapFrom = steps.count
        var failure: Error?
        doc.nodesBetween(from, to ?? from) { node, pos, _, _ in
            if failure != nil { return false }
            let attrsHere = attrs(node)
            if node.isTextblock && !node.hasMarkup(type, attrsHere)
                && canChangeType(doc, mapping.slice(mapFrom).map(pos), type) {
                do {
                    var convertNewlines: Bool?
                    if let lb = type.schema.linebreakReplacement {
                        let pre = type.whitespace == .pre, support = type.contentMatch.matchType(lb) != nil
                        if pre && !support { convertNewlines = false }
                        else if !pre && support { convertNewlines = true }
                    }
                    if convertNewlines == false { try replaceLinebreaks(node, pos, mapFrom) }
                    try clearIncompatible(mapping.slice(mapFrom).map(pos, assoc: 1), type, clearNewlines: convertNewlines == nil)
                    let m = mapping.slice(mapFrom)
                    let startM = m.map(pos, assoc: 1), endM = m.map(pos + node.nodeSize, assoc: 1)
                    try step(ReplaceAroundStep(startM, endM, startM + 1, endM - 1,
                                               Slice(Fragment(try type.create(attrsHere, .empty, marks: node.marks)),
                                                     openStart: 0, openEnd: 0), 1, structure: true))
                    if convertNewlines == true { try replaceNewlines(node, pos, mapFrom) }
                } catch {
                    failure = error
                }
                return false
            }
            return true
        }
        if let failure { throw failure }
        return self
    }

    private func replaceNewlines(_ node: Node, _ pos: Int, _ mapFrom: Int) throws {
        var targets: [Int] = []
        node.forEach { child, offset, _ in
            guard let text = child.text else { return }
            for m in newlineMatches(text) { targets.append(pos + 1 + offset + m.start) }
        }
        for t in targets {
            let start = mapping.slice(mapFrom).map(t)
            try replaceWith(start, start + 1, try node.type.schema.linebreakReplacement!.create())
        }
    }

    private func replaceLinebreaks(_ node: Node, _ pos: Int, _ mapFrom: Int) throws {
        var targets: [Int] = []
        node.forEach { child, offset, _ in
            if child.type === child.type.schema.linebreakReplacement { targets.append(pos + 1 + offset) }
        }
        for t in targets {
            let start = mapping.slice(mapFrom).map(t)
            try replaceWith(start, start + 1, node.type.schema.text("\n"))
        }
    }

    @discardableResult
    public func setNodeMarkup(_ pos: Int, type: NodeType? = nil, attrs: Attrs? = nil, marks: [Mark]? = nil) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw ProseError.range("No node at given position") }
        let type = type ?? node.type
        let newNode = try type.create(attrs, .empty, marks: marks ?? node.marks)
        if node.isLeaf { return try replaceWith(pos, pos + node.nodeSize, newNode) }
        guard type.validContent(node.content) else { throw ProseError.range("Invalid content for node type \(type.name)") }
        return try step(ReplaceAroundStep(pos, pos + node.nodeSize, pos + 1, pos + node.nodeSize - 1,
                                          Slice(Fragment(newNode), openStart: 0, openEnd: 0), 1, structure: true))
    }

    @discardableResult
    public func setNodeAttribute(_ pos: Int, _ attr: String, _ value: JSON) throws -> Self {
        try step(AttrStep(pos, attr, value))
    }

    @discardableResult
    public func setDocAttribute(_ attr: String, _ value: JSON) throws -> Self {
        try step(DocAttrStep(attr, value))
    }

    @discardableResult
    public func addNodeMark(_ pos: Int, _ mark: Mark) throws -> Self { try step(AddNodeMarkStep(pos, mark)) }

    @discardableResult
    public func removeNodeMark(_ pos: Int, _ mark: Mark) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw ProseError.range("No node at position \(pos)") }
        if mark.isInSet(node.marks) { try step(RemoveNodeMarkStep(pos, mark)) }
        return self
    }

    @discardableResult
    public func removeNodeMark(_ pos: Int, _ markType: MarkType) throws -> Self {
        guard let node = doc.nodeAt(pos) else { throw ProseError.range("No node at position \(pos)") }
        var set = node.marks
        var toRemove: [Step] = []
        while let found = markType.isInSet(set) {
            toRemove.append(RemoveNodeMarkStep(pos, found))
            set = found.removeFromSet(set)
        }
        for s in toRemove.reversed() { try step(s) }
        return self
    }

    @discardableResult
    public func split(_ pos: Int, depth: Int = 1, typesAfter: [NodeTypeAttrs?]? = nil) throws -> Self {
        let rPos = doc.resolve(pos)
        var before = Fragment.empty, after = Fragment.empty
        var d = rPos.depth, i = depth - 1
        let e = rPos.depth - depth
        while d > e {
            before = Fragment(rPos.node(d).copy(before))
            if let typesAfter, i < typesAfter.count, i >= 0, let ta = typesAfter[i] {
                after = Fragment(try ta.type.create(ta.attrs, after))
            } else {
                after = Fragment(rPos.node(d).copy(after))
            }
            d -= 1; i -= 1
        }
        return try step(ReplaceStep(pos, pos, Slice(before.append(after), openStart: depth, openEnd: depth), structure: true))
    }

    // MARK: Marks

    @discardableResult
    public func addMark(_ from: Int, _ to: Int, _ mark: Mark) throws -> Self {
        var added: [(Int, Int)] = []
        doc.nodesBetween(from, to) { node, pos, parent, _ in
            if !node.isInline { return true }
            if !mark.isInSet(node.marks) && parent!.type.allowsMarkType(mark.type) {
                let start = max(pos, from), end = min(pos + node.nodeSize, to)
                if let last = added.last, last.1 == start { added[added.count - 1].1 = end }
                else { added.append((start, end)) }
            }
            return true
        }
        for (f, t) in added { try step(AddMarkStep(f, t, mark)) }
        return self
    }

    /// Remove marks from inline nodes in the range. Pass `nil` to remove all marks.
    @discardableResult
    public func removeMark(_ from: Int, _ to: Int, _ mark: Mark?) throws -> Self {
        try removeMark(from, to) { node in
            guard let mark else { return node.marks }
            return mark.isInSet(node.marks) ? [mark] : nil
        }
    }

    @discardableResult
    public func removeMark(_ from: Int, _ to: Int, _ markType: MarkType) throws -> Self {
        try removeMark(from, to) { node in
            var set = node.marks
            var found: [Mark] = []
            while let m = markType.isInSet(set) { found.append(m); set = m.removeFromSet(set) }
            return found.isEmpty ? nil : found
        }
    }

    private func removeMark(_ from: Int, _ to: Int, select: (Node) -> [Mark]?) throws -> Self {
        struct Matched { var style: Mark; var from: Int; var to: Int; var step: Int }
        var matched: [Matched] = []
        var stepCount = 0
        doc.nodesBetween(from, to) { node, pos, _, _ in
            if !node.isInline || !node.isAtom { return true }
            stepCount += 1
            if let toRemove = select(node), !toRemove.isEmpty {
                let end = min(pos + node.nodeSize, to)
                for style in toRemove {
                    var foundIndex: Int?
                    for (j, m) in matched.enumerated() where m.step == stepCount - 1 && style == m.style { foundIndex = j }
                    if let j = foundIndex {
                        matched[j].to = end
                        matched[j].step = stepCount
                    } else {
                        matched.append(Matched(style: style, from: max(pos, from), to: end, step: stepCount))
                    }
                }
            }
            return true
        }
        for m in matched { try step(RemoveMarkStep(m.from, m.to, m.style)) }
        return self
    }

    /// Remove content and marks from the node at `pos` that are not valid in `parentType`.
    @discardableResult
    public func clearIncompatible(_ pos: Int, _ parentType: NodeType, match: ContentMatch? = nil,
                                  clearNewlines: Bool = true) throws -> Self {
        var match = match ?? parentType.contentMatch
        let node = doc.nodeAt(pos)!
        var replSteps: [Step] = []
        var cur = pos + 1
        for i in 0..<node.childCount {
            let child = node.child(i), end = cur + child.nodeSize
            if let allowed = match.matchType(child.type) {
                match = allowed
                for m in child.marks where !parentType.allowsMarkType(m.type) {
                    try step(RemoveMarkStep(cur, end, m))
                }
                if clearNewlines, let text = child.text, parentType.whitespace != .pre {
                    var slice: Slice?
                    for m in newlineMatches(text) {
                        if slice == nil {
                            slice = Slice(Fragment(parentType.schema.text(" ", marks: parentType.allowedMarks(child.marks))),
                                          openStart: 0, openEnd: 0)
                        }
                        replSteps.append(ReplaceStep(cur + m.start, cur + m.start + m.length, slice!))
                    }
                }
            } else {
                replSteps.append(ReplaceStep(cur, end, .empty))
            }
            cur = end
        }
        if !match.validEnd {
            let fill = match.fillBefore(.empty, toEnd: true)!
            try replace(cur, cur, Slice(fill, openStart: 0, openEnd: 0))
        }
        for s in replSteps.reversed() { try step(s) }
        return self
    }
}

// MARK: - Structure helpers

private func canCut(_ node: Node, _ start: Int, _ end: Int) -> Bool {
    (start == 0 || node.canReplace(start, node.childCount)) && (end == node.childCount || node.canReplace(0, end))
}

/// Find the depth a range can be lifted to, or `nil`.
public func liftTarget(_ range: NodeRange) -> Int? {
    let parent = range.parent
    let content = parent.content.cutByIndex(range.startIndex, range.endIndex)
    var depth = range.depth, contentBefore = 0, contentAfter = 0
    while true {
        let node = range.from.node(depth)
        let index = range.from.index(depth) + contentBefore, endIndex = range.to.indexAfter(depth) - contentAfter
        if depth < range.depth && node.canReplace(index, endIndex, content) { return depth }
        if depth == 0 || node.type.spec.isolating || !canCut(node, index, endIndex) { break }
        if index > 0 { contentBefore = 1 }
        if endIndex < node.childCount { contentAfter = 1 }
        depth -= 1
    }
    return nil
}

/// Find a set of wrapping node types that would allow a node of `nodeType` around the range.
public func findWrapping(_ range: NodeRange, _ nodeType: NodeType, attrs: Attrs? = nil,
                         innerRange: NodeRange? = nil) -> [NodeTypeAttrs]? {
    guard let around = findWrappingOutside(range, nodeType),
          let inner = findWrappingInside(innerRange ?? range, nodeType) else { return nil }
    return around.map { NodeTypeAttrs($0) } + [NodeTypeAttrs(nodeType, attrs)] + inner.map { NodeTypeAttrs($0) }
}

private func findWrappingOutside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent, startIndex = range.startIndex, endIndex = range.endIndex
    guard let around = parent.contentMatchAt(startIndex).findWrapping(type) else { return nil }
    let outer = around.first ?? type
    return parent.canReplaceWith(startIndex, endIndex, outer) ? around : nil
}

private func findWrappingInside(_ range: NodeRange, _ type: NodeType) -> [NodeType]? {
    let parent = range.parent, startIndex = range.startIndex, endIndex = range.endIndex
    let inner = parent.child(startIndex)
    guard let inside = type.contentMatch.findWrapping(inner.type) else { return nil }
    let lastType = inside.last ?? type
    var innerMatch: ContentMatch? = lastType.contentMatch
    var i = startIndex
    while let m = innerMatch, i < endIndex { innerMatch = m.matchType(parent.child(i).type); i += 1 }
    guard let m = innerMatch, m.validEnd else { return nil }
    return inside
}

private func canChangeType(_ doc: Node, _ pos: Int, _ type: NodeType) -> Bool {
    let rPos = doc.resolve(pos), index = rPos.index()
    return rPos.parent.canReplaceWith(index, index + 1, type)
}

/// Check whether splitting at the given position is allowed.
public func canSplit(_ doc: Node, _ pos: Int, depth: Int = 1, typesAfter: [NodeTypeAttrs?]? = nil) -> Bool {
    let rPos = doc.resolve(pos), base = rPos.depth - depth
    func typeAfter(_ i: Int) -> NodeTypeAttrs? {
        guard let typesAfter, i >= 0, i < typesAfter.count else { return nil }
        return typesAfter[i]
    }
    let innerType = typesAfter?.last.flatMap { $0 }?.type ?? rPos.parent.type
    if base < 0 || rPos.parent.type.spec.isolating
        || !rPos.parent.canReplace(rPos.index(), rPos.parent.childCount)
        || !innerType.validContent(rPos.parent.content.cutByIndex(rPos.index(), rPos.parent.childCount)) {
        return false
    }
    var d = rPos.depth - 1, i = depth - 2
    while d > base {
        let node = rPos.node(d), index = rPos.index(d)
        if node.type.spec.isolating { return false }
        var rest = node.content.cutByIndex(index, node.childCount)
        if let o = typeAfter(i + 1) {
            guard let n = try? o.type.create(o.attrs) else { return false }
            rest = rest.replaceChild(0, n)
        }
        let after = typeAfter(i)?.type ?? node.type
        if !node.canReplace(index + 1, node.childCount) || !after.validContent(rest) { return false }
        d -= 1; i -= 1
    }
    let index = rPos.indexAfter(base)
    let baseType = typeAfter(0)
    return rPos.node(base).canReplaceWith(index, index, baseType?.type ?? rPos.node(base + 1).type)
}

/// Test whether the blocks before and after a position can be joined.
public func canJoin(_ doc: Node, _ pos: Int) -> Bool {
    let rPos = doc.resolve(pos), index = rPos.index()
    return joinable(rPos.nodeBefore, rPos.nodeAfter) && rPos.parent.canReplace(index, index + 1)
}

private func canAppendWithSubstitutedLinebreaks(_ a: Node, _ b: Node) -> Bool {
    var match: ContentMatch? = a.contentMatchAt(a.childCount)
    let lb = a.type.schema.linebreakReplacement
    for i in 0..<b.childCount {
        let child = b.child(i)
        let type = child.type === lb ? a.type.schema.nodes["text"]! : child.type
        match = match?.matchType(type)
        if match == nil { return false }
        if !a.type.allowsMarks(child.marks) { return false }
    }
    return match!.validEnd
}

private func joinable(_ a: Node?, _ b: Node?) -> Bool {
    guard let a, let b else { return false }
    return !a.isLeaf && canAppendWithSubstitutedLinebreaks(a, b)
}

/// Find an ancestor of the given position that can be joined to the block before (or after, when `dir > 0`) it.
public func joinPoint(_ doc: Node, _ pos: Int, dir: Int = -1) -> Int? {
    let rPos = doc.resolve(pos)
    var pos = pos
    var d = rPos.depth
    while true {
        var before: Node?, after: Node?
        var index = rPos.index(d)
        if d == rPos.depth {
            before = rPos.nodeBefore
            after = rPos.nodeAfter
        } else if dir > 0 {
            before = rPos.node(d + 1)
            index += 1
            after = rPos.node(d).maybeChild(index)
        } else {
            before = rPos.node(d).maybeChild(index - 1)
            after = rPos.node(d + 1)
        }
        if let b = before, !b.isTextblock, joinable(b, after), rPos.node(d).canReplace(index, index + 1) { return pos }
        if d == 0 { break }
        pos = dir < 0 ? rPos.before(d) : rPos.after(d)
        d -= 1
    }
    return nil
}

/// Find a position at or around `pos` where a node of the given type can be inserted.
public func insertPoint(_ doc: Node, _ pos: Int, _ nodeType: NodeType) -> Int? {
    let rPos = doc.resolve(pos)
    if rPos.parent.canReplaceWith(rPos.index(), rPos.index(), nodeType) { return pos }
    if rPos.parentOffset == 0 {
        var d = rPos.depth - 1
        while d >= 0 {
            let index = rPos.index(d)
            if rPos.node(d).canReplaceWith(index, index, nodeType) { return rPos.before(d + 1) }
            if index > 0 { return nil }
            d -= 1
        }
    }
    if rPos.parentOffset == rPos.parent.content.size {
        var d = rPos.depth - 1
        while d >= 0 {
            let index = rPos.indexAfter(d)
            if rPos.node(d).canReplaceWith(index, index, nodeType) { return rPos.after(d + 1) }
            if index < rPos.node(d).childCount { return nil }
            d -= 1
        }
    }
    return nil
}

/// Find a position at or around `pos` where the slice can be inserted, for drag and drop.
public func dropPoint(_ doc: Node, _ pos: Int, _ slice: Slice) -> Int? {
    let rPos = doc.resolve(pos)
    if slice.content.size == 0 { return pos }
    var content = slice.content
    for _ in 0..<slice.openStart { content = content.firstChild!.content }
    let passes = slice.openStart == 0 && slice.size > 0 ? 2 : 1
    for pass in 1...passes {
        var d = rPos.depth
        while d >= 0 {
            var bias = d == rPos.depth ? 0
                : Double(rPos.pos) <= Double(rPos.start(d + 1) + rPos.end(d + 1)) / 2 ? -1 : 1
            for attempt in 0..<2 {
                if attempt > 0 {
                    if bias == 0 { break }
                    bias = -bias
                }
                let insertPos = rPos.index(d) + (bias > 0 ? 1 : 0)
                let parent = rPos.node(d)
                var fits = false
                if pass == 1 {
                    fits = parent.canReplace(insertPos, insertPos, content)
                } else if let wrapping = parent.contentMatchAt(insertPos).findWrapping(content.firstChild!.type) {
                    fits = wrapping.first.map { parent.canReplaceWith(insertPos, insertPos, $0) } ?? false
                }
                if fits { return bias == 0 ? rPos.pos : bias < 0 ? rPos.before(d + 1) : rPos.after(d + 1) }
            }
            d -= 1
        }
    }
    return nil
}

/// Matches of `/\r?\n|\r/g` in UTF-16 offsets.
func newlineMatches(_ text: String) -> [(start: Int, length: Int)] {
    let units = Array(text.utf16)
    var result: [(Int, Int)] = []
    var j = 0
    while j < units.count {
        if units[j] == 13 {
            let len = j + 1 < units.count && units[j + 1] == 10 ? 2 : 1
            result.append((j, len)); j += len
        } else if units[j] == 10 {
            result.append((j, 1)); j += 1
        } else { j += 1 }
    }
    return result
}
