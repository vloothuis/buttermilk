/// List commands from prosemirror-schema-list. Item type parameters accept one or more node types.
public enum ListCommands {
    private static func isItem(_ itemTypes: [NodeType], _ type: NodeType) -> Bool { itemTypes.contains { $0 === type } }

    /// Wrap the selection in a list of the given type.
    public static func wrapInList(_ listType: NodeType, attrs: Attrs? = nil) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection
            guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo) else { return false }
            let tr = dispatch != nil ? state.tr : nil
            guard (try? wrapRangeInList(tr, range, listType, attrs: attrs)) == true else { return false }
            if let dispatch, let tr { dispatch(tr.scrollIntoView()) }
            return true
        }
    }

    /// Wrap a range in a list. With a nil transaction, only check whether it is possible.
    @discardableResult
    public static func wrapRangeInList(_ tr: Transaction?, _ range: NodeRange, _ listType: NodeType, attrs: Attrs? = nil) throws -> Bool {
        var range = range, outerRange = range, doJoin = false
        let doc = range.from.doc
        if range.depth >= 2 && range.from.node(range.depth - 1).type.compatibleContent(listType) && range.startIndex == 0 {
            if range.from.index(range.depth - 1) == 0 { return false }
            let insert = doc.resolve(range.start - 2)
            outerRange = NodeRange(from: insert, to: insert, depth: range.depth)
            if range.endIndex < range.parent.childCount {
                range = NodeRange(from: range.from, to: doc.resolve(range.to.end(range.depth)), depth: range.depth)
            }
            doJoin = true
        }
        guard let wrap = findWrapping(outerRange, listType, attrs: attrs, innerRange: range) else { return false }
        if let tr { try doWrapInList(tr, range, wrap, doJoin, listType) }
        return true
    }

    private static func doWrapInList(_ tr: Transaction, _ range: NodeRange, _ wrappers: [NodeTypeAttrs],
                                     _ joinBefore: Bool, _ listType: NodeType) throws {
        var content = Fragment.empty
        for w in wrappers.reversed() { content = Fragment(try w.type.create(w.attrs, content)) }
        try tr.step(ReplaceAroundStep(range.start - (joinBefore ? 2 : 0), range.end, range.start, range.end,
                                      Slice(content, openStart: 0, openEnd: 0), wrappers.count, structure: true))
        var found = 0
        for (i, w) in wrappers.enumerated() where w.type === listType { found = i + 1 }
        let splitDepth = wrappers.count - found
        var splitPos = range.start + wrappers.count - (joinBefore ? 2 : 0)
        let parent = range.parent
        var first = true
        for i in range.startIndex..<range.endIndex {
            if !first && splitDepth > 0 && canSplit(tr.doc, splitPos, depth: splitDepth) {
                try tr.split(splitPos, depth: splitDepth)
                splitPos += 2 * splitDepth
            }
            splitPos += parent.child(i).nodeSize
            first = false
        }
    }

    /// Split a list item at the selection. In an empty last item, lift it out of a nested list.
    public static func splitListItem(_ itemTypes: [NodeType], itemAttrs: Attrs? = nil) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection, from = sel.resolvedFrom, to = sel.resolvedTo
            if let ns = sel as? NodeSelection, ns.node.isBlock { return false }
            if from.depth < 2 || !from.sameParent(to) { return false }
            let grandParent = from.node(-1)
            if !isItem(itemTypes, grandParent.type) { return false }
            if from.parent.content.size == 0 && from.node(-1).childCount == from.indexAfter(-1) {
                if from.depth == 3 || !isItem(itemTypes, from.node(-3).type) || from.index(-2) != from.node(-2).childCount - 1 {
                    return false
                }
                guard let dispatch else { return true }
                do {
                    var wrap = Fragment.empty
                    let depthBefore = from.index(-1) > 0 ? 1 : from.index(-2) > 0 ? 2 : 3
                    var d = from.depth - depthBefore
                    while d >= from.depth - 3 { wrap = Fragment(from.node(d).copy(wrap)); d -= 1 }
                    let depthAfter = from.indexAfter(-1) < from.node(-2).childCount ? 1
                        : from.indexAfter(-2) < from.node(-3).childCount ? 2 : 3
                    wrap = wrap.append(Fragment.from(from.node(-3).type.createAndFill()))
                    let start = from.before(from.depth - (depthBefore - 1))
                    let tr = try state.tr.replace(start, from.after(-depthAfter), Slice(wrap, openStart: 4 - depthBefore, openEnd: 0))
                    var selPos = -1
                    tr.doc.nodesBetween(start, tr.doc.content.size) { node, pos, _, _ in
                        if selPos > -1 { return false }
                        if node.isTextblock && node.content.size == 0 { selPos = pos + 1 }
                        return true
                    }
                    if selPos > -1 { tr.setSelection(Selection.near(tr.doc.resolve(selPos))) }
                    dispatch(tr.scrollIntoView())
                } catch { return false }
                return true
            }
            let nextType = to.pos == from.end() ? grandParent.contentMatchAt(0).defaultType : nil
            guard let tr = try? state.tr.delete(from.pos, to.pos) else { return false }
            let types: [NodeTypeAttrs?]? = nextType != nil || itemAttrs != nil
                ? [itemAttrs.map { NodeTypeAttrs(grandParent.type, $0) }, nextType.map { NodeTypeAttrs($0) }]
                : nil
            if !canSplit(tr.doc, from.pos, depth: 2, typesAfter: types) { return false }
            if let dispatch {
                guard (try? tr.split(from.pos, depth: 2, typesAfter: types)) != nil else { return false }
                dispatch(tr.scrollIntoView())
            }
            return true
        }
    }

    public static func splitListItem(_ itemType: NodeType, itemAttrs: Attrs? = nil) -> Command {
        splitListItem([itemType], itemAttrs: itemAttrs)
    }

    /// Like ``splitListItem(_:itemAttrs:)-(NodeType,_)``, but keep the active marks.
    public static func splitListItemKeepMarks(_ itemTypes: [NodeType], itemAttrs: Attrs? = nil) -> Command {
        let split = splitListItem(itemTypes, itemAttrs: itemAttrs)
        return { state, dispatch, view in
            split(state, dispatch.map { dispatch in { tr in
                let marks = state.storedMarks
                    ?? (state.selection.resolvedTo.parentOffset > 0 ? state.selection.resolvedFrom.marks() : nil)
                if let marks { tr.ensureMarks(marks) }
                dispatch(tr)
            } }, view)
        }
    }

    /// Lift the selected list items to the outer list, or out of the list.
    public static func liftListItem(_ itemTypes: [NodeType]) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection
            guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo, { n in
                n.childCount > 0 && isItem(itemTypes, n.firstChild!.type)
            }) else { return false }
            guard let dispatch else { return true }
            do {
                if isItem(itemTypes, sel.resolvedFrom.node(range.depth - 1).type) {
                    return try liftToOuterList(state, dispatch, range)
                }
                return try liftOutOfList(state, dispatch, range)
            } catch { return false }
        }
    }

    public static func liftListItem(_ itemType: NodeType) -> Command { liftListItem([itemType]) }

    private static func liftToOuterList(_ state: EditorState, _ dispatch: (Transaction) -> Void, _ range: NodeRange) throws -> Bool {
        var range = range
        let tr = state.tr, end = range.end, endOfList = range.to.end(range.depth)
        let itemType = range.parent.child(range.endIndex - 1).type
        if end < endOfList {
            try tr.step(ReplaceAroundStep(end - 1, endOfList, end, endOfList,
                                          Slice(Fragment(try itemType.create(nil, Fragment(range.parent.copy()))), openStart: 1, openEnd: 0),
                                          1, structure: true))
            range = NodeRange(from: tr.doc.resolve(range.from.pos), to: tr.doc.resolve(endOfList), depth: range.depth)
        }
        guard let target = liftTarget(range) else { return false }
        try tr.lift(range, target)
        let after = tr.doc.resolve(tr.mapping.map(end, assoc: -1) - 1)
        if canJoin(tr.doc, after.pos), after.nodeBefore!.type === after.nodeAfter!.type { try tr.join(after.pos) }
        dispatch(tr.scrollIntoView())
        return true
    }

    private static func liftOutOfList(_ state: EditorState, _ dispatch: (Transaction) -> Void, _ range: NodeRange) throws -> Bool {
        let tr = state.tr, list = range.parent
        var pos = range.end
        var i = range.endIndex - 1
        while i > range.startIndex {
            pos -= list.child(i).nodeSize
            try tr.delete(pos - 1, pos + 1)
            i -= 1
        }
        let rStart = tr.doc.resolve(range.start), item = rStart.nodeAfter!
        if tr.mapping.map(range.end, assoc: 1) != range.start + item.nodeSize { return false }
        let atStart = range.startIndex == 0, atEnd = range.endIndex == list.childCount
        let parent = rStart.node(-1), indexBefore = rStart.index(-1)
        if !parent.canReplace(indexBefore + (atStart ? 0 : 1), indexBefore + 1,
                              item.content.append(atEnd ? .empty : Fragment(list))) {
            return false
        }
        let start = rStart.pos, end = start + item.nodeSize
        let content = (atStart ? Fragment.empty : Fragment(list.copy(.empty)))
            .append(atEnd ? .empty : Fragment(list.copy(.empty)))
        try tr.step(ReplaceAroundStep(start - (atStart ? 1 : 0), end + (atEnd ? 1 : 0), start + 1, end - 1,
                                      Slice(content, openStart: atStart ? 0 : 1, openEnd: atEnd ? 0 : 1), atStart ? 0 : 1))
        dispatch(tr.scrollIntoView())
        return true
    }

    /// Sink the selected list items into a nested list inside the item before them.
    public static func sinkListItem(_ itemTypes: [NodeType]) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection
            guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo, { n in
                n.childCount > 0 && isItem(itemTypes, n.firstChild!.type)
            }) else { return false }
            let startIndex = range.startIndex
            if startIndex == 0 { return false }
            let parent = range.parent, nodeBefore = parent.child(startIndex - 1)
            if !isItem(itemTypes, nodeBefore.type) { return false }
            guard let dispatch else { return true }
            do {
                let nestedBefore = nodeBefore.lastChild.map { $0.type === parent.type } ?? false
                let inner = nestedBefore ? Fragment(try nodeBefore.lastChild!.lastChild!.type.create()) : Fragment.empty
                let slice = Slice(Fragment(try nodeBefore.type.create(nil, Fragment(try parent.type.create(nil, inner)))),
                                  openStart: nestedBefore ? 3 : 1, openEnd: 0)
                let before = range.start, after = range.end
                let tr = state.tr
                try tr.step(ReplaceAroundStep(before - (nestedBefore ? 3 : 1), after, before, after, slice, 1, structure: true))
                dispatch(tr.scrollIntoView())
            } catch { return false }
            return true
        }
    }

    public static func sinkListItem(_ itemType: NodeType) -> Command { sinkListItem([itemType]) }
}
