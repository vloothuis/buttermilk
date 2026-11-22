/// Create a step that replaces `from..<to` with `slice`, fitting the slice into the document
/// structure. Returns `nil` when nothing needs to change.
public func replaceStep(_ doc: Node, _ from: Int, _ to: Int? = nil, _ slice: Slice = .empty) -> Step? {
    let to = to ?? from
    if from == to && slice.size == 0 { return nil }
    let rFrom = doc.resolve(from), rTo = doc.resolve(to)
    if fitsTrivially(rFrom, rTo, slice) { return ReplaceStep(from, to, slice) }
    return Fitter(rFrom, rTo, slice).fit()
}

private func fitsTrivially(_ from: ResolvedPos, _ to: ResolvedPos, _ slice: Slice) -> Bool {
    slice.openStart == 0 && slice.openEnd == 0 && from.start() == to.start()
        && from.parent.canReplace(from.index(), to.index(), slice.content)
}

private struct Fittable {
    let sliceDepth: Int
    let frontierDepth: Int
    let parent: Node?
    var inject: Fragment?
    var wrap: [NodeType]?
}

private final class Fitter {
    var frontier: [(type: NodeType, match: ContentMatch)] = []
    var placed = Fragment.empty
    let from: ResolvedPos
    let to: ResolvedPos
    var unplaced: Slice

    init(_ from: ResolvedPos, _ to: ResolvedPos, _ unplaced: Slice) {
        self.from = from
        self.to = to
        self.unplaced = unplaced
        for i in 0...from.depth {
            let node = from.node(i)
            frontier.append((node.type, node.contentMatchAt(from.indexAfter(i))))
        }
        var i = from.depth
        while i > 0 { placed = Fragment(from.node(i).copy(placed)); i -= 1 }
    }

    var depth: Int { frontier.count - 1 }

    func fit() -> Step? {
        while unplaced.size > 0 {
            if let fit = findFittable() { placeNodes(fit) }
            else if !openMore() { dropNode() }
        }
        let moveInline = mustMoveInline(), placedSize = placed.size - depth - from.depth
        guard let rTo = close(moveInline < 0 ? to : from.doc.resolve(moveInline)) else { return nil }
        var content = placed, openStart = from.depth, openEnd = rTo.depth
        while openStart > 0 && openEnd > 0 && content.childCount == 1 {
            content = content.firstChild!.content
            openStart -= 1; openEnd -= 1
        }
        let slice = Slice(content, openStart: openStart, openEnd: openEnd)
        if moveInline > -1 {
            return ReplaceAroundStep(from.pos, moveInline, to.pos, to.end(), slice, placedSize)
        }
        if slice.size > 0 || from.pos != to.pos { return ReplaceStep(from.pos, rTo.pos, slice) }
        return nil
    }

    func findFittable() -> Fittable? {
        var startDepth = unplaced.openStart
        var cur = unplaced.content, openEnd = unplaced.openEnd
        var d = 0
        while d < startDepth {
            let node = cur.firstChild!
            if cur.childCount > 1 { openEnd = 0 }
            if node.type.spec.isolating && openEnd <= d { startDepth = d; break }
            cur = node.content
            d += 1
        }
        for pass in 1...2 {
            var sliceDepth = pass == 1 ? startDepth : unplaced.openStart
            while sliceDepth >= 0 {
                let fragment: Fragment
                var parent: Node?
                if sliceDepth > 0 {
                    parent = contentAt(unplaced.content, sliceDepth - 1).firstChild
                    fragment = parent!.content
                } else {
                    fragment = unplaced.content
                }
                let first = fragment.firstChild
                var frontierDepth = depth
                while frontierDepth >= 0 {
                    let (type, match) = frontier[frontierDepth]
                    if pass == 1 {
                        if let first {
                            if match.matchType(first.type) != nil {
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent)
                            }
                            if let inject = match.fillBefore(Fragment(first), toEnd: false) {
                                return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, inject: inject)
                            }
                        } else if let parent, type.compatibleContent(parent.type) {
                            return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent)
                        }
                    } else if let first, let wrap = match.findWrapping(first.type) {
                        return Fittable(sliceDepth: sliceDepth, frontierDepth: frontierDepth, parent: parent, wrap: wrap)
                    }
                    if let parent, match.matchType(parent.type) != nil { break }
                    frontierDepth -= 1
                }
                sliceDepth -= 1
            }
        }
        return nil
    }

    func openMore() -> Bool {
        let content = unplaced.content, openStart = unplaced.openStart
        var openEnd = unplaced.openEnd
        if maxOpen(content, -1) <= openStart { return false }
        if unplaced.size > 1 && maxOpen(content, 1) > openEnd { openEnd += 1 }
        unplaced = Slice(content, openStart: openStart + 1, openEnd: openEnd)
        return true
    }

    func dropNode() {
        let content = unplaced.content, openStart = unplaced.openStart, openEnd = unplaced.openEnd
        let inner = contentAt(content, openStart)
        if inner.childCount <= 1 && openStart > 0 {
            let openAtEnd = content.size - openStart <= openStart + inner.size
            unplaced = Slice(dropFromFragment(content, openStart - 1, 1), openStart: openStart - 1,
                             openEnd: openAtEnd ? openStart - 1 : openEnd)
        } else {
            unplaced = Slice(dropFromFragment(content, openStart, 1), openStart: openStart, openEnd: openEnd)
        }
    }

    func placeNodes(_ fit: Fittable) {
        let sliceDepth = fit.sliceDepth, frontierDepth = fit.frontierDepth, parent = fit.parent
        while depth > frontierDepth { closeFrontierNode() }
        if let wrap = fit.wrap { for t in wrap { openFrontierNode(t) } }
        let slice = unplaced, fragment = parent?.content ?? slice.content
        let openStart = slice.openStart - sliceDepth
        var taken = 0
        var add: [Node] = []
        let type = frontier[frontierDepth].type
        var match = frontier[frontierDepth].match
        if let inject = fit.inject {
            add.append(contentsOf: inject.children)
            match = match.matchFragment(inject)!
        }
        var openEndCount = (fragment.size + sliceDepth) - (slice.content.size - slice.openEnd)
        while taken < fragment.childCount {
            let next = fragment.child(taken)
            guard let matches = match.matchType(next.type) else { break }
            taken += 1
            if taken > 1 || openStart == 0 || next.content.size > 0 {
                match = matches
                add.append(closeNodeStart(next.mark(type.allowedMarks(next.marks)), taken == 1 ? openStart : 0,
                                          taken == fragment.childCount ? openEndCount : -1))
            }
        }
        let toEnd = taken == fragment.childCount
        if !toEnd { openEndCount = -1 }
        placed = addToFragment(placed, frontierDepth, Fragment.from(add))
        frontier[frontierDepth].match = match
        if toEnd && openEndCount < 0, let parent, parent.type === frontier[depth].type, frontier.count > 1 {
            closeFrontierNode()
        }
        var cur = add.last
        var i = 0
        while let c = cur, i < openEndCount {
            frontier.append((c.type, c.contentMatchAt(c.childCount)))
            cur = c.lastChild
            i += 1
        }
        unplaced = !toEnd ? Slice(dropFromFragment(slice.content, sliceDepth, taken), openStart: sliceDepth, openEnd: slice.openEnd)
            : sliceDepth == 0 ? .empty
            : Slice(dropFromFragment(slice.content, sliceDepth - 1, 1), openStart: sliceDepth - 1,
                    openEnd: openEndCount < 0 ? slice.openEnd : sliceDepth - 1)
    }

    func mustMoveInline() -> Int {
        if !to.parent.isTextblock { return -1 }
        let top = frontier[depth]
        if !top.type.isTextblock || contentAfterFits(to, to.depth, top.type, top.match, false) == nil {
            return -1
        }
        if to.depth == depth, let level = findCloseLevel(to), level.depth == depth { return -1 }
        var d = to.depth, after = to.after(d)
        while d > 1 {
            d -= 1
            if after != to.end(d) { break }
            after += 1
        }
        return after
    }

    func findCloseLevel(_ rTo: ResolvedPos) -> (depth: Int, fit: Fragment, move: ResolvedPos)? {
        var i = min(depth, rTo.depth)
        scan: while i >= 0 {
            defer { i -= 1 }
            let (type, match) = frontier[i]
            let dropInner = i < rTo.depth && rTo.end(i + 1) == rTo.pos + (rTo.depth - (i + 1))
            guard let fit = contentAfterFits(rTo, i, type, match, dropInner) else { continue }
            var d = i - 1
            while d >= 0 {
                let (t, m) = frontier[d]
                guard let matches = contentAfterFits(rTo, d, t, m, true), matches.childCount == 0 else { continue scan }
                d -= 1
            }
            return (i, fit, dropInner ? rTo.doc.resolve(rTo.after(i + 1)) : rTo)
        }
        return nil
    }

    func close(_ rTo: ResolvedPos) -> ResolvedPos? {
        guard let close = findCloseLevel(rTo) else { return nil }
        while depth > close.depth { closeFrontierNode() }
        if close.fit.childCount > 0 { placed = addToFragment(placed, close.depth, close.fit) }
        let moved = close.move
        if close.depth + 1 <= moved.depth {
            for d in (close.depth + 1)...moved.depth {
                let node = moved.node(d)
                let add = node.type.contentMatch.fillBefore(node.content, toEnd: true, startIndex: moved.index(d))!
                openFrontierNode(node.type, node.attrs, add)
            }
        }
        return moved
    }

    func openFrontierNode(_ type: NodeType, _ attrs: Attrs? = nil, _ content: Fragment = .empty) {
        frontier[depth].match = frontier[depth].match.matchType(type)!
        placed = addToFragment(placed, depth, Fragment(try! type.create(attrs, content)))
        frontier.append((type, type.contentMatch))
    }

    func closeFrontierNode() {
        let open = frontier.removeLast()
        let add = open.match.fillBefore(.empty, toEnd: true)!
        if add.childCount > 0 { placed = addToFragment(placed, frontier.count, add) }
    }
}

private func dropFromFragment(_ fragment: Fragment, _ depth: Int, _ count: Int) -> Fragment {
    if depth == 0 { return fragment.cutByIndex(count, fragment.childCount) }
    return fragment.replaceChild(0, fragment.firstChild!.copy(dropFromFragment(fragment.firstChild!.content, depth - 1, count)))
}

private func addToFragment(_ fragment: Fragment, _ depth: Int, _ content: Fragment) -> Fragment {
    if depth == 0 { return fragment.append(content) }
    return fragment.replaceChild(fragment.childCount - 1,
                                 fragment.lastChild!.copy(addToFragment(fragment.lastChild!.content, depth - 1, content)))
}

private func contentAt(_ fragment: Fragment, _ depth: Int) -> Fragment {
    var f = fragment
    for _ in 0..<depth { f = f.firstChild!.content }
    return f
}

private func closeNodeStart(_ node: Node, _ openStart: Int, _ openEnd: Int) -> Node {
    if openStart <= 0 { return node }
    var frag = node.content
    if openStart > 1 {
        frag = frag.replaceChild(0, closeNodeStart(frag.firstChild!, openStart - 1, frag.childCount == 1 ? openEnd - 1 : 0))
    }
    frag = node.type.contentMatch.fillBefore(frag)!.append(frag)
    if openEnd <= 0 { frag = frag.append(node.type.contentMatch.matchFragment(frag)!.fillBefore(.empty, toEnd: true)!) }
    return node.copy(frag)
}

private func contentAfterFits(_ to: ResolvedPos, _ depth: Int, _ type: NodeType, _ match: ContentMatch,
                              _ open: Bool) -> Fragment? {
    let node = to.node(depth), index = open ? to.indexAfter(depth) : to.index(depth)
    if index == node.childCount && !type.compatibleContent(node.type) { return nil }
    guard let fit = match.fillBefore(node.content, toEnd: true, startIndex: index) else { return nil }
    return invalidMarks(type, node.content, index) ? nil : fit
}

private func invalidMarks(_ type: NodeType, _ fragment: Fragment, _ start: Int) -> Bool {
    var i = start
    while i < fragment.childCount {
        if !type.allowsMarks(fragment.child(i).marks) { return true }
        i += 1
    }
    return false
}

private func definesContent(_ type: NodeType) -> Bool { type.spec.defining || type.spec.definingForContent == true }

private func maxOpen(_ frag: Fragment, _ side: Int) -> Int {
    var frag = frag, count = 0
    while true {
        guard let ch = side < 0 ? frag.firstChild : frag.lastChild, !ch.isAtom else { return count }
        frag = ch.content
        count += 1
    }
}

func replaceRange(_ tr: Transform, _ from: Int, _ to: Int, _ slice: Slice) throws {
    if slice.size == 0 { try tr.deleteRange(from, to); return }
    let rFrom = tr.doc.resolve(from), rTo = tr.doc.resolve(to)
    if fitsTrivially(rFrom, rTo, slice) { try tr.step(ReplaceStep(from, to, slice)); return }

    var targetDepths = coveredDepths(rFrom, rTo)
    if targetDepths.last == 0 { targetDepths.removeLast() }
    var preferredTarget = -(rFrom.depth + 1)
    targetDepths.insert(preferredTarget, at: 0)
    var d = rFrom.depth, pos = rFrom.pos - 1
    while d > 0 {
        let spec = rFrom.node(d).type.spec
        if spec.defining || spec.definingAsContext == true || spec.isolating { break }
        if targetDepths.contains(d) { preferredTarget = d }
        else if rFrom.before(d) == pos { targetDepths.insert(-d, at: 1) }
        d -= 1; pos -= 1
    }
    let preferredTargetIndex = targetDepths.firstIndex(of: preferredTarget)!

    var leftNodes: [Node] = []
    var preferredDepth = slice.openStart
    var content = slice.content
    var i = 0
    while true {
        let node = content.firstChild!
        leftNodes.append(node)
        if i == slice.openStart { break }
        content = node.content
        i += 1
    }
    var dd = preferredDepth - 1
    while dd >= 0 {
        let leftNode = leftNodes[dd], def = definesContent(leftNode.type)
        if def && !leftNode.sameMarkup(rFrom.node(abs(preferredTarget) - 1)) { preferredDepth = dd }
        else if def || !leftNode.type.isTextblock { break }
        dd -= 1
    }

    var j = slice.openStart
    while j >= 0 {
        defer { j -= 1 }
        let openDepth = (j + preferredDepth + 1) % (slice.openStart + 1)
        guard openDepth < leftNodes.count else { continue }
        let insert = leftNodes[openDepth]
        for k in 0..<targetDepths.count {
            var targetDepth = targetDepths[(k + preferredTargetIndex) % targetDepths.count]
            var expand = true
            if targetDepth < 0 { expand = false; targetDepth = -targetDepth }
            let parent = rFrom.node(targetDepth - 1), index = rFrom.index(targetDepth - 1)
            if parent.canReplaceWith(index, index, insert.type, marks: insert.marks) {
                try tr.replace(rFrom.before(targetDepth), expand ? rTo.after(targetDepth) : to,
                               Slice(closeFragment(slice.content, 0, slice.openStart, openDepth, nil),
                                     openStart: openDepth, openEnd: slice.openEnd))
                return
            }
        }
    }

    let startSteps = tr.steps.count
    var f = from, t = to
    var k = targetDepths.count - 1
    while k >= 0 {
        try tr.replace(f, t, slice)
        if tr.steps.count > startSteps { break }
        let depth = targetDepths[k]
        k -= 1
        if depth < 0 { continue }
        f = rFrom.before(depth); t = rTo.after(depth)
    }
}

private func closeFragment(_ fragment: Fragment, _ depth: Int, _ oldOpen: Int, _ newOpen: Int, _ parent: Node?) -> Fragment {
    var fragment = fragment
    if depth < oldOpen {
        let first = fragment.firstChild!
        fragment = fragment.replaceChild(0, first.copy(closeFragment(first.content, depth + 1, oldOpen, newOpen, first)))
    }
    if depth > newOpen {
        let match = parent!.contentMatchAt(0)
        let start = match.fillBefore(fragment)!.append(fragment)
        fragment = start.append(match.matchFragment(start)!.fillBefore(.empty, toEnd: true)!)
    }
    return fragment
}

func deleteRange(_ tr: Transform, _ from: Int, _ to: Int) throws {
    var from = from, to = to
    var rFrom = tr.doc.resolve(from), rTo = tr.doc.resolve(to)
    if rFrom.parent.isTextblock && rTo.parent.isTextblock && rFrom.start() != rTo.start()
        && rFrom.parentOffset == 0 && rTo.parentOffset == 0 {
        let shared = rFrom.sharedDepth(to)
        var isolated = false
        var d = rFrom.depth
        while d > shared { if rFrom.node(d).type.spec.isolating { isolated = true }; d -= 1 }
        d = rTo.depth
        while d > shared { if rTo.node(d).type.spec.isolating { isolated = true }; d -= 1 }
        if !isolated {
            d = rFrom.depth
            while d > 0 && from == rFrom.start(d) { from = rFrom.before(d); d -= 1 }
            d = rTo.depth
            while d > 0 && to == rTo.start(d) { to = rTo.before(d); d -= 1 }
            rFrom = tr.doc.resolve(from)
            rTo = tr.doc.resolve(to)
        }
    }
    let covered = coveredDepths(rFrom, rTo)
    for (i, depth) in covered.enumerated() {
        let last = i == covered.count - 1
        if (last && depth == 0) || rFrom.node(depth).type.contentMatch.validEnd {
            try tr.delete(rFrom.start(depth), rTo.end(depth)); return
        }
        if depth > 0 && (last || rFrom.node(depth - 1).canReplace(rFrom.index(depth - 1), rTo.indexAfter(depth - 1))) {
            try tr.delete(rFrom.before(depth), rTo.after(depth)); return
        }
    }
    var d = 1
    while d <= rFrom.depth && d <= rTo.depth {
        if from - rFrom.start(d) == rFrom.depth - d && to > rFrom.end(d) && rTo.end(d) - to != rTo.depth - d
            && rFrom.start(d - 1) == rTo.start(d - 1)
            && rFrom.node(d - 1).canReplace(rFrom.index(d - 1), rTo.index(d - 1)) {
            try tr.delete(rFrom.before(d), to); return
        }
        d += 1
    }
    try tr.delete(from, to)
}

private func coveredDepths(_ from: ResolvedPos, _ to: ResolvedPos) -> [Int] {
    var result: [Int] = []
    var d = min(from.depth, to.depth)
    while d >= 0 {
        let start = from.start(d)
        if start < from.pos - (from.depth - d) || to.end(d) > to.pos + (to.depth - d)
            || from.node(d).type.spec.isolating || to.node(d).type.spec.isolating { break }
        if start == to.start(d)
            || (d == from.depth && d == to.depth && from.parent.inlineContent && to.parent.inlineContent
                && d > 0 && to.start(d - 1) == start - 1) {
            result.append(d)
        }
        d -= 1
    }
    return result
}
