/// A cursor between two block nodes where no text selection is possible, such as between two
/// horizontal rules or before a table at the start of the document. Port of prosemirror-gapcursor.
///
/// Node specs can set `extra["allowGapCursor"]` (Bool) to allow or forbid gap cursors directly
/// inside that node, and `extra["createGapCursor"]` (true) to make a node need a gap cursor
/// around it.
public final class GapCursor: Selection {
    public override class var jsonID: String { "gapcursor" }

    public init(_ pos: ResolvedPos) { super.init(pos, pos) }

    public override var visible: Bool { false }

    public override func map(_ doc: Node, _ mapping: Mappable) -> Selection {
        let pos = doc.resolve(mapping.map(head))
        return GapCursor.valid(pos) ? GapCursor(pos) : Selection.near(pos)
    }

    public override func content() -> Slice { .empty }

    public override func eq(_ other: Selection) -> Bool {
        guard let o = other as? GapCursor else { return false }
        return o.head == head
    }

    public override func toJSON() -> JSON { ["type": "gapcursor", "pos": .number(Double(head))] }

    public override func getBookmark() -> SelectionBookmark { GapBookmark(pos: anchor) }

    /// Register the `gapcursor` JSON type with ``Selection/fromJSON(_:_:)``. Safe to call more than once.
    public static func registerJSON() {
        if !registered {
            registered = true
            Selection.register("gapcursor") { doc, json in GapCursor(doc.resolve(try checkedPosition(doc, json["pos"]))) }
        }
    }
    nonisolated(unsafe) private static var registered = false

    /// Whether a gap cursor is allowed at `pos`.
    public static func valid(_ pos: ResolvedPos) -> Bool {
        let parent = pos.parent
        if parent.inlineContent || !closedBefore(pos) || !closedAfter(pos) { return false }
        if let override = parent.type.spec.extra["allowGapCursor"] as? Bool { return override }
        return parent.contentMatchAt(pos.index()).defaultType?.isTextblock ?? false
    }

    /// Find the nearest valid gap cursor position from `pos` in direction `dir`.
    public static func findFrom(_ pos: ResolvedPos, _ dir: Int, mustMove: Bool = false) -> ResolvedPos? {
        var pos = pos, mustMove = mustMove
        search: while true {
            if !mustMove && valid(pos) { return pos }
            var p = pos.pos
            var next: Node
            var d = pos.depth
            while true {
                let parent = pos.node(d)
                if dir > 0 ? pos.indexAfter(d) < parent.childCount : pos.index(d) > 0 {
                    next = parent.child(dir > 0 ? pos.indexAfter(d) : pos.index(d) - 1)
                    break
                } else if d == 0 {
                    return nil
                }
                p += dir
                let cur = pos.doc.resolve(p)
                if valid(cur) { return cur }
                d -= 1
            }
            while true {
                guard let inside = dir > 0 ? next.firstChild : next.lastChild else {
                    if next.isAtom && !next.isText && !NodeSelection.isSelectable(next) {
                        pos = pos.doc.resolve(p + next.nodeSize * dir)
                        mustMove = false
                        continue search
                    }
                    break
                }
                next = inside
                p += dir
                let cur = pos.doc.resolve(p)
                if valid(cur) { return cur }
            }
            return nil
        }
    }

    // MARK: Plugin

    /// Arrow key command that moves into a gap cursor position. `axis` is horizontal or vertical.
    public static func arrow(vertical: Bool, _ dir: Int) -> Command {
        let dirName: TextDirection = vertical ? (dir > 0 ? .down : .up) : (dir > 0 ? .right : .left)
        return { state, dispatch, view in
            let sel = state.selection
            var start = dir > 0 ? sel.resolvedTo : sel.resolvedFrom
            var mustMove = sel.isEmpty
            if sel is TextSelection {
                let atEnd = view?.endOfTextblock(dirName, state)
                    ?? (dir > 0 ? start.parentOffset == start.parent.content.size : start.parentOffset == 0)
                if !atEnd || start.depth == 0 { return false }
                mustMove = false
                start = state.doc.resolve(dir > 0 ? start.after() : start.before())
            }
            guard let found = findFrom(start, dir, mustMove: mustMove) else { return false }
            dispatch?(state.tr.setSelection(GapCursor(found)))
            return true
        }
    }

    /// The gap cursor plugin: arrow keys can move into gap positions. Typing at a gap cursor goes
    /// through the normal selection replacement, which wraps the text in a textblock. The view
    /// draws the cursor for ``GapCursor`` selections.
    public static func plugin() -> Plugin {
        registerJSON()
        var props = EditorProps()
        props.handleKeyDown = Keymap.handler([
            "ArrowLeft": arrow(vertical: false, -1), "ArrowRight": arrow(vertical: false, 1),
            "ArrowUp": arrow(vertical: true, -1), "ArrowDown": arrow(vertical: true, 1),
        ])
        return Plugin(props: props, extra: ["gapCursor": true])
    }
}

struct GapBookmark: SelectionBookmark {
    let pos: Int
    func map(_ mapping: Mappable) -> SelectionBookmark { GapBookmark(pos: mapping.map(pos)) }
    func resolve(_ doc: Node) -> Selection {
        let p = doc.resolve(pos)
        return GapCursor.valid(p) ? GapCursor(p) : Selection.near(p)
    }
}

private func needsGap(_ type: NodeType) -> Bool {
    type.isAtom || type.spec.isolating || type.spec.extra["createGapCursor"] as? Bool == true
}

private func closedBefore(_ pos: ResolvedPos) -> Bool {
    var d = pos.depth
    while d >= 0 {
        let index = pos.index(d), parent = pos.node(d)
        if index == 0 {
            if parent.type.spec.isolating { return true }
            d -= 1
            continue
        }
        var before = parent.child(index - 1)
        while true {
            if (before.childCount == 0 && !before.inlineContent) || needsGap(before.type) { return true }
            if before.inlineContent { return false }
            before = before.lastChild!
        }
    }
    return true
}

private func closedAfter(_ pos: ResolvedPos) -> Bool {
    var d = pos.depth
    while d >= 0 {
        let index = pos.indexAfter(d), parent = pos.node(d)
        if index == parent.childCount {
            if parent.type.spec.isolating { return true }
            d -= 1
            continue
        }
        var after = parent.child(index)
        while true {
            if (after.childCount == 0 && !after.inlineContent) || needsGap(after.type) { return true }
            if after.inlineContent { return false }
            after = after.firstChild!
        }
    }
    return true
}
