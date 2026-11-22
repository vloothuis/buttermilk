/// Run a transaction builder. A failure means the command does not apply.
private func build(_ f: () throws -> Void) -> Bool {
    do { try f(); return true } catch { return false }
}

/// The standard editing commands from prosemirror-commands.
public enum Commands {
    /// Delete the selection, if there is one.
    public static let deleteSelection: Command = { state, dispatch, _ in
        if state.selection.isEmpty { return false }
        if let dispatch { return build { dispatch(try state.tr.deleteSelection().scrollIntoView()) } }
        return true
    }

    static func atBlockStart(_ state: EditorState, _ view: EditorViewing?) -> ResolvedPos? {
        guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
        let atStart = view?.endOfTextblock(.backward, state) ?? (cursor.parentOffset == 0)
        return atStart ? cursor : nil
    }

    static func atBlockEnd(_ state: EditorState, _ view: EditorViewing?) -> ResolvedPos? {
        guard let cursor = (state.selection as? TextSelection)?.cursor else { return nil }
        let atEnd = view?.endOfTextblock(.forward, state) ?? (cursor.parentOffset >= cursor.parent.content.size)
        return atEnd ? cursor : nil
    }

    /// At the start of a textblock, join it with the block before it, or lift it.
    public static let joinBackward: Command = { state, dispatch, view in
        guard let cursor = atBlockStart(state, view) else { return false }
        guard let cut = findCutBefore(cursor) else {
            guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
            if let dispatch { return build { dispatch(try state.tr.lift(range, target).scrollIntoView()) } }
            return true
        }
        let before = cut.nodeBefore!
        if deleteBarrier(state, cut, dispatch, -1) { return true }

        if cursor.parent.content.size == 0 && (textblockAt(before, start: false) || NodeSelection.isSelectable(before)) {
            var depth = cursor.depth
            while true {
                if let del = replaceStep(state.doc, cursor.before(depth), cursor.after(depth), .empty) as? ReplaceStep,
                   del.slice.size < del.to - del.from {
                    if let dispatch {
                        return build {
                            let tr = state.tr
                            try tr.step(del)
                            tr.setSelection(textblockAt(before, start: false)
                                ? Selection.findFrom(tr.doc.resolve(tr.mapping.map(cut.pos, assoc: -1)), -1)!
                                : NodeSelection.create(tr.doc, cut.pos - before.nodeSize))
                            dispatch(tr.scrollIntoView())
                        }
                    }
                    return true
                }
                if depth == 1 || cursor.node(depth - 1).childCount > 1 { break }
                depth -= 1
            }
        }

        if before.isAtom && cut.depth == cursor.depth - 1 {
            if let dispatch { return build { dispatch(try state.tr.delete(cut.pos - before.nodeSize, cut.pos).scrollIntoView()) } }
            return true
        }
        return false
    }

    /// Join the textblock at the cursor with the textblock before it, without other fallbacks.
    public static let joinTextblockBackward: Command = { state, dispatch, view in
        guard let cursor = atBlockStart(state, view), let cut = findCutBefore(cursor) else { return false }
        return joinTextblocksAround(state, cut, dispatch)
    }

    public static let joinTextblockForward: Command = { state, dispatch, view in
        guard let cursor = atBlockEnd(state, view), let cut = findCutAfter(cursor) else { return false }
        return joinTextblocksAround(state, cut, dispatch)
    }

    static func joinTextblocksAround(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: ((Transaction) -> Void)?) -> Bool {
        var beforeText = cut.nodeBefore!, beforePos = cut.pos - 1
        while !beforeText.isTextblock {
            if beforeText.type.spec.isolating { return false }
            guard let child = beforeText.lastChild else { return false }
            beforeText = child
            beforePos -= 1
        }
        var afterText = cut.nodeAfter!, afterPos = cut.pos + 1
        while !afterText.isTextblock {
            if afterText.type.spec.isolating { return false }
            guard let child = afterText.firstChild else { return false }
            afterText = child
            afterPos += 1
        }
        guard let step = replaceStep(state.doc, beforePos, afterPos, .empty) else { return false }
        if let rs = step as? ReplaceStep {
            if rs.from != beforePos || rs.slice.size >= afterPos - beforePos { return false }
        } else if let ras = step as? ReplaceAroundStep, ras.from != beforePos {
            return false
        }
        if let dispatch {
            return build {
                let tr = state.tr
                try tr.step(step)
                tr.setSelection(TextSelection.create(tr.doc, beforePos))
                dispatch(tr.scrollIntoView())
            }
        }
        return true
    }

    static func textblockAt(_ node: Node, start: Bool, only: Bool = false) -> Bool {
        var scan: Node? = node
        while let s = scan {
            if s.isTextblock { return true }
            if only && s.childCount != 1 { return false }
            scan = start ? s.firstChild : s.lastChild
        }
        return false
    }

    /// At the start of a textblock, select the selectable node before it.
    public static let selectNodeBackward: Command = { state, dispatch, view in
        let sel = state.selection
        guard sel.isEmpty else { return false }
        var cut: ResolvedPos? = sel.resolvedHead
        if sel.resolvedHead.parent.isTextblock {
            let atStart = view?.endOfTextblock(.backward, state) ?? (sel.resolvedHead.parentOffset == 0)
            if !atStart { return false }
            cut = findCutBefore(sel.resolvedHead)
        }
        guard let cut, let node = cut.nodeBefore, NodeSelection.isSelectable(node) else { return false }
        dispatch?(state.tr.setSelection(NodeSelection.create(state.doc, cut.pos - node.nodeSize)).scrollIntoView())
        return true
    }

    static func findCutBefore(_ pos: ResolvedPos) -> ResolvedPos? {
        if !pos.parent.type.spec.isolating {
            var i = pos.depth - 1
            while i >= 0 {
                if pos.index(i) > 0 { return pos.doc.resolve(pos.before(i + 1)) }
                if pos.node(i).type.spec.isolating { break }
                i -= 1
            }
        }
        return nil
    }

    /// At the end of a textblock, join it with the block after it.
    public static let joinForward: Command = { state, dispatch, view in
        guard let cursor = atBlockEnd(state, view), let cut = findCutAfter(cursor) else { return false }
        let after = cut.nodeAfter!
        if deleteBarrier(state, cut, dispatch, 1) { return true }

        if cursor.parent.content.size == 0 && (textblockAt(after, start: true) || NodeSelection.isSelectable(after)) {
            if let del = replaceStep(state.doc, cursor.before(), cursor.after(), .empty) as? ReplaceStep,
               del.slice.size < del.to - del.from {
                if let dispatch {
                    return build {
                        let tr = state.tr
                        try tr.step(del)
                        tr.setSelection(textblockAt(after, start: true)
                            ? Selection.findFrom(tr.doc.resolve(tr.mapping.map(cut.pos, assoc: 1)), 1)!
                            : NodeSelection.create(tr.doc, tr.mapping.map(cut.pos, assoc: 1)))
                        dispatch(tr.scrollIntoView())
                    }
                }
                return true
            }
        }

        if after.isAtom && cut.depth == cursor.depth - 1 {
            if let dispatch { return build { dispatch(try state.tr.delete(cut.pos, cut.pos + after.nodeSize).scrollIntoView()) } }
            return true
        }
        return false
    }

    /// At the end of a textblock, select the selectable node after it.
    public static let selectNodeForward: Command = { state, dispatch, view in
        let sel = state.selection
        guard sel.isEmpty else { return false }
        var cut: ResolvedPos? = sel.resolvedHead
        if sel.resolvedHead.parent.isTextblock {
            let atEnd = view?.endOfTextblock(.forward, state)
                ?? (sel.resolvedHead.parentOffset >= sel.resolvedHead.parent.content.size)
            if !atEnd { return false }
            cut = findCutAfter(sel.resolvedHead)
        }
        guard let cut, let node = cut.nodeAfter, NodeSelection.isSelectable(node) else { return false }
        dispatch?(state.tr.setSelection(NodeSelection.create(state.doc, cut.pos)).scrollIntoView())
        return true
    }

    static func findCutAfter(_ pos: ResolvedPos) -> ResolvedPos? {
        if !pos.parent.type.spec.isolating {
            var i = pos.depth - 1
            while i >= 0 {
                let parent = pos.node(i)
                if pos.index(i) + 1 < parent.childCount { return pos.doc.resolve(pos.after(i + 1)) }
                if parent.type.spec.isolating { break }
                i -= 1
            }
        }
        return nil
    }

    /// Join the selected block, or the closest ancestor block, with the sibling above it.
    public static let joinUp: Command = { state, dispatch, _ in
        let sel = state.selection
        let nodeSel = sel as? NodeSelection
        let point: Int
        if let nodeSel {
            if nodeSel.node.isTextblock || !canJoin(state.doc, sel.from) { return false }
            point = sel.from
        } else {
            guard let p = joinPoint(state.doc, sel.from, dir: -1) else { return false }
            point = p
        }
        if let dispatch {
            return build {
                let tr = state.tr
                try tr.join(point)
                if nodeSel != nil {
                    tr.setSelection(NodeSelection.create(tr.doc, point - state.doc.resolve(point).nodeBefore!.nodeSize))
                }
                dispatch(tr.scrollIntoView())
            }
        }
        return true
    }

    /// Join the selected block, or the closest ancestor block, with the sibling below it.
    public static let joinDown: Command = { state, dispatch, _ in
        let sel = state.selection
        let point: Int
        if let ns = sel as? NodeSelection {
            if ns.node.isTextblock || !canJoin(state.doc, sel.to) { return false }
            point = sel.to
        } else {
            guard let p = joinPoint(state.doc, sel.to, dir: 1) else { return false }
            point = p
        }
        if let dispatch { return build { dispatch(try state.tr.join(point).scrollIntoView()) } }
        return true
    }

    /// Lift the selected blocks out of their parent.
    public static let lift: Command = { state, dispatch, _ in
        let sel = state.selection
        guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo), let target = liftTarget(range) else { return false }
        if let dispatch { return build { dispatch(try state.tr.lift(range, target).scrollIntoView()) } }
        return true
    }

    /// In a code block, insert a newline.
    public static let newlineInCode: Command = { state, dispatch, _ in
        let head = state.selection.resolvedHead
        if !head.parent.type.spec.code || !head.sameParent(state.selection.resolvedAnchor) { return false }
        if let dispatch { return build { dispatch(try state.tr.insertText("\n").scrollIntoView()) } }
        return true
    }

    static func defaultBlockAt(_ match: ContentMatch) -> NodeType? {
        for i in 0..<match.edgeCount {
            let type = match.edge(i).type
            if type.isTextblock && !type.hasRequiredAttrs() { return type }
        }
        return nil
    }

    /// In a code block, create a default block after it and move the cursor there.
    public static let exitCode: Command = { state, dispatch, _ in
        let head = state.selection.resolvedHead
        if !head.parent.type.spec.code || !head.sameParent(state.selection.resolvedAnchor) { return false }
        let above = head.node(-1), after = head.indexAfter(-1)
        guard let type = defaultBlockAt(above.contentMatchAt(after)), above.canReplaceWith(after, after, type) else { return false }
        if let dispatch {
            return build {
                let pos = head.after()
                let tr = try state.tr.replaceWith(pos, pos, type.createAndFill()!)
                tr.setSelection(Selection.near(tr.doc.resolve(pos), bias: 1))
                dispatch(tr.scrollIntoView())
            }
        }
        return true
    }

    /// When a block node is selected, create an empty paragraph before or after it.
    public static let createParagraphNear: Command = { state, dispatch, _ in
        let sel = state.selection, from = sel.resolvedFrom, to = sel.resolvedTo
        if sel is AllSelection || from.parent.inlineContent || to.parent.inlineContent { return false }
        guard let type = defaultBlockAt(to.parent.contentMatchAt(to.indexAfter())), type.isTextblock else { return false }
        if let dispatch {
            return build {
                let side = (from.parentOffset == 0 && to.index() < to.parent.childCount ? from : to).pos
                let tr = try state.tr.insert(side, type.createAndFill()!)
                tr.setSelection(TextSelection.create(tr.doc, side + 1))
                dispatch(tr.scrollIntoView())
            }
        }
        return true
    }

    /// If the cursor is in an empty liftable textblock, lift it.
    public static let liftEmptyBlock: Command = { state, dispatch, _ in
        guard let cursor = (state.selection as? TextSelection)?.cursor, cursor.parent.content.size == 0 else { return false }
        if cursor.depth > 1 && cursor.after() != cursor.end(-1) {
            let before = cursor.before()
            if canSplit(state.doc, before) {
                if let dispatch { return build { dispatch(try state.tr.split(before).scrollIntoView()) } }
                return true
            }
        }
        guard let range = cursor.blockRange(), let target = liftTarget(range) else { return false }
        if let dispatch { return build { dispatch(try state.tr.lift(range, target).scrollIntoView()) } }
        return true
    }

    /// Like ``splitBlock``, but `splitNode` can choose the type of the node after the split.
    public static func splitBlockAs(_ splitNode: ((Node, _ atEnd: Bool, ResolvedPos) -> NodeTypeAttrs?)? = nil) -> Command {
        return { state, dispatch, _ in
            if let ns = state.selection as? NodeSelection, ns.node.isBlock {
                let from = ns.resolvedFrom
                if from.parentOffset == 0 || !canSplit(state.doc, from.pos) { return false }
                if let dispatch { return build { dispatch(try state.tr.split(from.pos).scrollIntoView()) } }
                return true
            }
            if state.selection.resolvedFrom.depth == 0 { return false }
            let tr = state.tr
            if !state.selection.isEmpty && (state.selection is TextSelection || state.selection is AllSelection) {
                guard (try? tr.deleteSelection()) != nil else { return false }
            }
            let from = tr.selection.resolvedFrom, mapFrom = tr.steps.count
            var types: [NodeTypeAttrs?] = []
            var splitDepth = 0
            var deflt: NodeType?
            var atEnd = false, atStart = false
            var d = from.depth
            while true {
                let node = from.node(d)
                if node.isBlock {
                    atEnd = from.end(d) == from.pos + (from.depth - d)
                    atStart = from.start(d) == from.pos - (from.depth - d)
                    deflt = defaultBlockAt(from.node(d - 1).contentMatchAt(from.indexAfter(d - 1)))
                    let splitType = splitNode?(from.parent, atEnd, from)
                    types.insert(splitType ?? (atEnd && deflt != nil ? NodeTypeAttrs(deflt!) : nil), at: 0)
                    splitDepth = d
                    break
                } else {
                    if d == 1 { return false }
                    types.insert(nil, at: 0)
                }
                d -= 1
            }
            let splitPos = from.pos
            var can = canSplit(tr.doc, splitPos, depth: types.count, typesAfter: types)
            if !can {
                types[0] = deflt.map { NodeTypeAttrs($0) }
                can = canSplit(tr.doc, splitPos, depth: types.count, typesAfter: types)
            }
            if !can { return false }
            guard (try? tr.split(splitPos, depth: types.count, typesAfter: types)) != nil else { return false }
            if !atEnd && atStart && from.node(splitDepth).type !== deflt {
                let mapping = tr.mapping.slice(mapFrom)
                let first = mapping.map(from.before(splitDepth)), rFirst = tr.doc.resolve(first)
                if let deflt, from.node(splitDepth - 1).canReplaceWith(rFirst.index(), rFirst.index() + 1, deflt) {
                    guard (try? tr.setNodeMarkup(mapping.map(from.before(splitDepth)), type: deflt)) != nil else { return false }
                }
            }
            dispatch?(tr.scrollIntoView())
            return true
        }
    }

    /// Split the parent block of the selection.
    public static let splitBlock: Command = splitBlockAs()

    /// Like ``splitBlock``, but keep the active marks.
    public static let splitBlockKeepMarks: Command = { state, dispatch, view in
        splitBlock(state, dispatch.map { dispatch in { tr in
            let marks = state.storedMarks
                ?? (state.selection.resolvedTo.parentOffset > 0 ? state.selection.resolvedFrom.marks() : nil)
            if let marks { tr.ensureMarks(marks) }
            dispatch(tr)
        } }, view)
    }

    /// Select the node that wraps the selection.
    public static let selectParentNode: Command = { state, dispatch, _ in
        let from = state.selection.resolvedFrom
        let same = from.sharedDepth(state.selection.to)
        if same == 0 { return false }
        let pos = from.before(same)
        dispatch?(state.tr.setSelection(NodeSelection.create(state.doc, pos)))
        return true
    }

    /// Select the whole document.
    public static let selectAll: Command = { state, dispatch, _ in
        dispatch?(state.tr.setSelection(AllSelection(state.doc)))
        return true
    }

    static func joinMaybeClear(_ state: EditorState, _ pos: ResolvedPos, _ dispatch: ((Transaction) -> Void)?) -> Bool {
        let index = pos.index()
        guard let before = pos.nodeBefore, let after = pos.nodeAfter, before.type.compatibleContent(after.type) else { return false }
        if before.content.size == 0 && pos.parent.canReplace(index - 1, index) {
            if let dispatch { return build { dispatch(try state.tr.delete(pos.pos - before.nodeSize, pos.pos).scrollIntoView()) } }
            return true
        }
        if !pos.parent.canReplace(index, index + 1) || !(after.isTextblock || canJoin(state.doc, pos.pos)) { return false }
        if let dispatch { return build { dispatch(try state.tr.join(pos.pos).scrollIntoView()) } }
        return true
    }

    static func deleteBarrier(_ state: EditorState, _ cut: ResolvedPos, _ dispatch: ((Transaction) -> Void)?, _ dir: Int) -> Bool {
        let before = cut.nodeBefore!, after = cut.nodeAfter!
        let isolated = before.type.spec.isolating || after.type.spec.isolating
        if !isolated && joinMaybeClear(state, cut, dispatch) { return true }

        let canDelAfter = !isolated && cut.parent.canReplace(cut.index(), cut.index() + 1)
        let match = before.contentMatchAt(before.childCount)
        if canDelAfter, let conn = match.findWrapping(after.type), match.matchType(conn.first ?? after.type)?.validEnd == true {
            if let dispatch {
                return build {
                    let end = cut.pos + after.nodeSize
                    var wrap = Fragment.empty
                    for t in conn.reversed() { wrap = Fragment(try t.create(nil, wrap)) }
                    wrap = Fragment(before.copy(wrap))
                    let tr = state.tr
                    try tr.step(ReplaceAroundStep(cut.pos - 1, end, cut.pos, end, Slice(wrap, openStart: 1, openEnd: 0),
                                                  conn.count, structure: true))
                    let joinAt = tr.doc.resolve(end + 2 * conn.count)
                    if let na = joinAt.nodeAfter, na.type === before.type, canJoin(tr.doc, joinAt.pos) { try tr.join(joinAt.pos) }
                    dispatch(tr.scrollIntoView())
                }
            }
            return true
        }

        let selAfter = after.type.spec.isolating || (dir > 0 && isolated) ? nil : Selection.findFrom(cut, 1)
        if let selAfter, let range = selAfter.resolvedFrom.blockRange(selAfter.resolvedTo),
           let target = liftTarget(range), target >= cut.depth {
            if let dispatch { return build { dispatch(try state.tr.lift(range, target).scrollIntoView()) } }
            return true
        }

        if canDelAfter && textblockAt(after, start: true, only: true) && textblockAt(before, start: false) {
            var at = before
            var wrap: [Node] = []
            while true {
                wrap.append(at)
                if at.isTextblock { break }
                at = at.lastChild!
            }
            var afterText = after, afterDepth = 1
            while !afterText.isTextblock { afterText = afterText.firstChild!; afterDepth += 1 }
            if at.canReplace(at.childCount, at.childCount, afterText.content) {
                if let dispatch {
                    return build {
                        var end = Fragment.empty
                        for n in wrap.reversed() { end = Fragment(n.copy(end)) }
                        let tr = state.tr
                        try tr.step(ReplaceAroundStep(cut.pos - wrap.count, cut.pos + after.nodeSize,
                                                      cut.pos + afterDepth, cut.pos + after.nodeSize - afterDepth,
                                                      Slice(end, openStart: wrap.count, openEnd: 0), 0, structure: true))
                        dispatch(tr.scrollIntoView())
                    }
                }
                return true
            }
        }
        return false
    }

    static func selectTextblockSide(_ side: Int) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection, pos = side < 0 ? sel.resolvedFrom : sel.resolvedTo
            var depth = pos.depth
            while pos.node(depth).isInline {
                if depth == 0 { return false }
                depth -= 1
            }
            if !pos.node(depth).isTextblock { return false }
            dispatch?(state.tr.setSelection(TextSelection.create(state.doc, side < 0 ? pos.start(depth) : pos.end(depth))))
            return true
        }
    }

    /// Move the cursor to the start of the current textblock.
    public static let selectTextblockStart: Command = selectTextblockSide(-1)
    /// Move the cursor to the end of the current textblock.
    public static let selectTextblockEnd: Command = selectTextblockSide(1)

    /// Wrap the selection in a node of the given type.
    public static func wrapIn(_ nodeType: NodeType, attrs: Attrs? = nil) -> Command {
        return { state, dispatch, _ in
            let sel = state.selection
            guard let range = sel.resolvedFrom.blockRange(sel.resolvedTo),
                  let wrapping = findWrapping(range, nodeType, attrs: attrs) else { return false }
            if let dispatch { return build { dispatch(try state.tr.wrap(range, wrapping).scrollIntoView()) } }
            return true
        }
    }

    /// Turn the selected textblocks into the given type.
    public static func setBlockType(_ nodeType: NodeType, attrs: Attrs? = nil) -> Command {
        return { state, dispatch, _ in
            var applicable = false
            for range in state.selection.ranges where !applicable {
                state.doc.nodesBetween(range.from.pos, range.to.pos) { node, pos, _, _ in
                    if applicable { return false }
                    if !node.isTextblock || node.hasMarkup(nodeType, attrs) { return true }
                    if node.type === nodeType {
                        applicable = true
                    } else {
                        let rp = state.doc.resolve(pos), index = rp.index()
                        applicable = rp.parent.canReplaceWith(index, index + 1, nodeType)
                    }
                    return true
                }
            }
            if !applicable { return false }
            if let dispatch {
                return build {
                    let tr = state.tr
                    for range in state.selection.ranges { try tr.setBlockType(range.from.pos, range.to.pos, nodeType, attrs: attrs) }
                    dispatch(tr.scrollIntoView())
                }
            }
            return true
        }
    }

    static func markApplies(_ doc: Node, _ ranges: [SelectionRange], _ type: MarkType, _ enterAtoms: Bool) -> Bool {
        for range in ranges {
            var can = range.from.depth == 0 ? doc.inlineContent && doc.type.allowsMarkType(type) : false
            doc.nodesBetween(range.from.pos, range.to.pos) { node, pos, _, _ in
                if can || !enterAtoms && node.isAtom && node.isInline && pos >= range.from.pos && pos + node.nodeSize <= range.to.pos {
                    return false
                }
                can = node.inlineContent && node.type.allowsMarkType(type)
                return true
            }
            if can { return true }
        }
        return false
    }

    static func removeInlineAtoms(_ ranges: [SelectionRange]) -> [SelectionRange] {
        var result: [SelectionRange] = []
        for range in ranges {
            var from = range.from
            let to = range.to
            from.doc.nodesBetween(from.pos, to.pos) { node, pos, _, _ in
                if node.isAtom && node.content.size > 0 && node.isInline && pos >= from.pos && pos + node.nodeSize <= to.pos {
                    if pos + 1 > from.pos { result.append(SelectionRange(from, from.doc.resolve(pos + 1))) }
                    from = from.doc.resolve(pos + 1 + node.content.size)
                    return false
                }
                return true
            }
            if from.pos < to.pos { result.append(SelectionRange(from, to)) }
        }
        return result
    }

    /// Options for ``toggleMark(_:attrs:options:)``.
    public struct ToggleMarkOptions {
        /// Remove the mark when any of the selection has it. When false, add it unless all of the selection has it.
        public var removeWhenPresent = true
        /// Apply marks inside inline atom nodes that have content.
        public var enterInlineAtoms = true
        /// Include leading and trailing whitespace in the marked range.
        public var includeWhitespace = false
        public init(removeWhenPresent: Bool = true, enterInlineAtoms: Bool = true, includeWhitespace: Bool = false) {
            self.removeWhenPresent = removeWhenPresent; self.enterInlineAtoms = enterInlineAtoms
            self.includeWhitespace = includeWhitespace
        }
    }

    /// Wraps `command` so the transactions it dispatches carry the action name `name`, unless
    /// they already have one. The history uses the name for "Undo <name>".
    public static func named(_ name: String, _ command: @escaping Command) -> Command {
        return { state, dispatch, view in
            command(state, dispatch.map { dispatch in { tr in dispatch(tr.actionName == nil ? tr.setActionName(name) : tr) } }, view)
        }
    }

    /// Toggle a mark on the selection. With an empty selection, toggle it in the stored marks.
    public static func toggleMark(_ markType: MarkType, attrs: Attrs? = nil, options: ToggleMarkOptions = .init()) -> Command {
        let enterAtoms = options.enterInlineAtoms, dropSpace = !options.includeWhitespace
        return named("Formatting") { state, dispatch, _ in
            let sel = state.selection
            let cursor = (sel as? TextSelection)?.cursor
            var ranges = sel.ranges
            if (sel.isEmpty && cursor == nil) || !markApplies(state.doc, ranges, markType, enterAtoms) { return false }
            guard let dispatch else { return true }
            if let cursor {
                if markType.isInSet(state.storedMarks ?? cursor.marks()) != nil {
                    dispatch(state.tr.removeStoredMark(markType))
                } else {
                    guard let mark = try? markType.create(attrs) else { return false }
                    dispatch(state.tr.addStoredMark(mark))
                }
                return true
            }
            let tr = state.tr
            if !enterAtoms { ranges = removeInlineAtoms(ranges) }
            let add: Bool
            if options.removeWhenPresent {
                add = !ranges.contains { state.doc.rangeHasMark($0.from.pos, $0.to.pos, markType) }
            } else {
                add = !ranges.allSatisfy { r in
                    var missing = false
                    tr.doc.nodesBetween(r.from.pos, r.to.pos) { node, pos, parent, _ in
                        if missing { return false }
                        missing = markType.isInSet(node.marks) == nil && parent != nil && parent!.type.allowsMarkType(markType)
                            && !(node.isText && node.textBetween(Swift.max(0, r.from.pos - pos),
                                                                 Swift.min(node.nodeSize, r.to.pos - pos)).allSatisfy(\.isWhitespace))
                        return true
                    }
                    return !missing
                }
            }
            return build {
                for r in ranges {
                    if !add {
                        try tr.removeMark(r.from.pos, r.to.pos, markType)
                    } else {
                        var from = r.from.pos, to = r.to.pos
                        let start = r.from.nodeAfter, end = r.to.nodeBefore
                        let spaceStart = dropSpace && start?.isText == true ? leadingSpace(start!.text!) : 0
                        let spaceEnd = dropSpace && end?.isText == true ? trailingSpace(end!.text!) : 0
                        if from + spaceStart < to { from += spaceStart; to -= spaceEnd }
                        try tr.addMark(from, to, markType.create(attrs))
                    }
                }
                dispatch(tr.scrollIntoView())
            }
        }
    }

    static func leadingSpace(_ s: String) -> Int { s.prefix(while: \.isWhitespace).utf16.count }
    static func trailingSpace(_ s: String) -> Int { String(s.reversed().prefix(while: \.isWhitespace)).utf16.count }

    static func wrapDispatchForJoin(_ dispatch: @escaping (Transaction) -> Void, _ isJoinable: @escaping (Node, Node) -> Bool) -> (Transaction) -> Void {
        return { tr in
            if !tr.isGeneric { return dispatch(tr) }
            var ranges: [Int] = []
            for map in tr.mapping.maps {
                for j in ranges.indices { ranges[j] = map.map(ranges[j], assoc: 1) }
                map.forEach { _, _, from, to in ranges.append(from); ranges.append(to) }
            }
            var joinable: [Int] = []
            var i = 0
            while i < ranges.count {
                let from = ranges[i], to = ranges[i + 1]
                let rFrom = tr.doc.resolve(from), depth = rFrom.sharedDepth(to), parent = rFrom.node(depth)
                var index = rFrom.indexAfter(depth), pos = rFrom.after(depth + 1)
                while pos <= to {
                    guard let after = parent.maybeChild(index) else { break }
                    if index > 0 && !joinable.contains(pos) {
                        let before = parent.child(index - 1)
                        if before.type === after.type && isJoinable(before, after) { joinable.append(pos) }
                    }
                    pos += after.nodeSize
                    index += 1
                }
                i += 2
            }
            joinable.sort()
            for p in joinable.reversed() where canJoin(tr.doc, p) { try? tr.join(p) }
            dispatch(tr)
        }
    }

    /// Wrap a command so that, after it runs, adjacent nodes it touched are joined when `isJoinable` allows.
    public static func autoJoin(_ command: @escaping Command, _ isJoinable: @escaping (Node, Node) -> Bool) -> Command {
        return { state, dispatch, view in command(state, dispatch.map { wrapDispatchForJoin($0, isJoinable) }, view) }
    }

    /// Like ``autoJoin(_:_:)-(_,(Node,Node)->Bool)``, joining nodes whose type name is in `types`.
    public static func autoJoin(_ command: @escaping Command, _ types: [String]) -> Command {
        autoJoin(command) { a, _ in types.contains(a.type.name) }
    }

    /// Try each command in turn and stop at the first that applies.
    public static func chain(_ commands: Command...) -> Command { chain(commands) }

    public static func chain(_ commands: [Command]) -> Command {
        return { state, dispatch, view in
            for c in commands where c(state, dispatch, view) { return true }
            return false
        }
    }

    public static let backspace: Command = chain(deleteSelection, joinBackward, selectNodeBackward)
    public static let del: Command = chain(deleteSelection, joinForward, selectNodeForward)

    /// The base key bindings for non-Apple platforms.
    public static let pcBaseKeymap: [String: Command] = [
        "Enter": chain(newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock),
        "Mod-Enter": exitCode,
        "Backspace": backspace,
        "Mod-Backspace": backspace,
        "Shift-Backspace": backspace,
        "Delete": del,
        "Mod-Delete": del,
        "Mod-a": selectAll,
    ]

    /// The base key bindings for macOS and iOS.
    public static let macBaseKeymap: [String: Command] = pcBaseKeymap.merging([
        "Ctrl-h": backspace,
        "Alt-Backspace": backspace,
        "Ctrl-d": del,
        "Ctrl-Alt-Backspace": del,
        "Alt-Delete": del,
        "Alt-d": del,
        "Ctrl-a": selectTextblockStart,
        "Ctrl-e": selectTextblockEnd,
    ]) { a, _ in a }

    /// The base key bindings for the current platform.
    public static var baseKeymap: [String: Command] {
        #if os(macOS) || os(iOS) || os(visionOS)
        return macBaseKeymap
        #else
        return pcBaseKeymap
        #endif
    }
}
