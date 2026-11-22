import Foundation

/// An Emacs-style kill ring. Kill commands delete a range and store it as a ``Slice``; yank
/// inserts the latest entry, keeping its structure and marks. Consecutive kills extend the same
/// entry, appending forward kills and prepending backward ones. The ring lives in the plugin
/// state, so each editor has its own. Without the plugin, kills only delete and yank fails.
public enum KillRing {
    /// The plugin state.
    public struct State {
        /// The entries, latest first. Each slice is cut from the document root, so that
        /// consecutive kills join where their open nodes meet.
        public var entries: [Slice] = []
        /// The cursor position after the last kill, while the next transaction may extend it.
        var lastKill: Int?
        /// The range and entry index of the last yank, while yank-pop may replace it.
        var lastYank: (from: Int, to: Int, index: Int)?
    }

    enum Meta {
        case kill(Slice, prepend: Bool)
        case yank(from: Int, to: Int, index: Int)
    }

    static let key = PluginKey<State>("killRing")

    /// The kill ring plugin, keeping at most `capacity` entries.
    public static func plugin(capacity: Int = 60) -> Plugin {
        Plugin(key: key, state: StateField<State>(
            initialize: { _, _ in State() },
            apply: { tr, ring, _, state in
                var ring = ring
                switch tr.getMeta(key, as: Meta.self) {
                case let .kill(slice, prepend)?:
                    if ring.lastKill != nil, let first = ring.entries.first {
                        ring.entries[0] = prepend ? join(slice, first) : join(first, slice)
                    } else {
                        ring.entries.insert(slice, at: 0)
                        if ring.entries.count > max(capacity, 1) { ring.entries.removeLast(ring.entries.count - max(capacity, 1)) }
                    }
                    ring.lastKill = state.selection.from
                    ring.lastYank = nil
                case let .yank(from, to, index)?:
                    ring.lastKill = nil
                    ring.lastYank = (from, to, index)
                case nil:
                    if tr.docChanged || tr.selectionSet { ring.lastKill = nil; ring.lastYank = nil }
                }
                return ring
            }))
    }

    /// The plugin state, or nil without the plugin.
    public static func getState(_ state: EditorState) -> State? { key.getState(state) }

    /// Joins two slices killed next to each other, merging the open nodes where they meet.
    static func join(_ a: Slice, _ b: Slice) -> Slice {
        if a.size == 0 { return b }
        if b.size == 0 { return a }
        return Slice(joinFragments(a.content, a.openEnd, b.content, b.openStart), openStart: a.openStart, openEnd: b.openEnd)
    }

    static func joinFragments(_ a: Fragment, _ openA: Int, _ b: Fragment, _ openB: Int) -> Fragment {
        guard openA > 0, openB > 0, let last = a.lastChild, let first = b.firstChild,
              !last.isText, last.type === first.type else { return a.append(b) }
        let merged = last.copy(joinFragments(last.content, openA - 1, first.content, openB - 1))
        var children = Array(a.children.dropLast()) + [merged]
        children += b.children.dropFirst()
        return Fragment.fromArray(children)
    }

    /// Drops the open wrapper nodes that the slice does not need.
    static func trimmed(_ slice: Slice) -> Slice {
        var slice = slice
        while slice.openStart > 0, slice.openEnd > 0, slice.content.childCount == 1, let only = slice.content.firstChild {
            slice = Slice(only.content, openStart: slice.openStart - 1, openEnd: slice.openEnd - 1)
        }
        return slice
    }

    /// Deletes `from..<to`, storing the deleted content in the ring.
    public static func kill(from: Int, to: Int, prepend: Bool = false) -> Command {
        return { state, dispatch, _ in
            guard from < to else { return false }
            if let dispatch {
                let slice = state.doc.slice(from, to, includeParents: true)
                guard let tr = try? state.tr.delete(from, to) else { return false }
                dispatch(tr.setMeta(key, Meta.kill(slice, prepend: prepend)).setActionName("Kill").scrollIntoView())
            }
            return true
        }
    }

    /// Kills the selection.
    public static let killRegion: Command = { state, dispatch, view in
        let sel = state.selection
        return kill(from: sel.from, to: sel.to)(state, dispatch, view)
    }

    /// The position where the next textblock starts, or nil when there is none.
    static func boundary(_ state: EditorState, _ pos: ResolvedPos, _ dir: Int) -> Int? {
        guard pos.depth > 0 else { return nil }
        let outside = state.doc.resolve(dir > 0 ? pos.after() : pos.before())
        guard let next = Selection.findFrom(outside, dir, textOnly: true) else { return nil }
        return next.from
    }

    /// Kills to the end of the textblock, or the block boundary when the cursor is at the end.
    public static let killToEndOfTextblock: Command = { state, dispatch, view in
        let sel = state.selection
        if !sel.isEmpty { return killRegion(state, dispatch, view) }
        let pos = sel.resolvedFrom
        guard pos.parent.isTextblock else { return false }
        let end = pos.end()
        if pos.pos < end { return kill(from: pos.pos, to: end)(state, dispatch, view) }
        guard let next = boundary(state, pos, 1) else { return false }
        return kill(from: pos.pos, to: next)(state, dispatch, view)
    }

    static func killWord(_ dir: Int) -> Command {
        return { state, dispatch, view in
            let sel = state.selection
            if !sel.isEmpty { return killRegion(state, dispatch, view) }
            let pos = sel.resolvedFrom
            guard pos.parent.isTextblock else { return false }
            let start = pos.start()
            let text = Array(pos.parent.textBetween(0, pos.parent.content.size, leafText: { _ in "\u{FFFC}" }).utf16)
            var i = pos.pos - start
            if dir > 0 ? i == text.count : i == 0 {
                guard let next = boundary(state, pos, dir) else { return false }
                return dir > 0 ? kill(from: pos.pos, to: next)(state, dispatch, view)
                               : kill(from: next, to: pos.pos, prepend: true)(state, dispatch, view)
            }
            func isWord(_ u: UInt16) -> Bool {
                guard let s = Unicode.Scalar(u) else { return true }
                return CharacterSet.alphanumerics.contains(s)
            }
            if dir > 0 {
                while i < text.count, !isWord(text[i]) { i += 1 }
                while i < text.count, isWord(text[i]) { i += 1 }
                return kill(from: pos.pos, to: start + i)(state, dispatch, view)
            }
            while i > 0, !isWord(text[i - 1]) { i -= 1 }
            while i > 0, isWord(text[i - 1]) { i -= 1 }
            return kill(from: start + i, to: pos.pos, prepend: true)(state, dispatch, view)
        }
    }

    /// Kills to the end of the next word, or the block boundary at the end of a textblock.
    public static let killWordForward: Command = killWord(1)
    /// Kills to the start of the previous word, or the block boundary at the start of a textblock.
    public static let killWordBackward: Command = killWord(-1)

    static func insert(_ state: EditorState, _ index: Int, from: Int, to: Int,
                       _ dispatch: ((Transaction) -> Void)?) -> Bool {
        guard let ring = key.getState(state), index < ring.entries.count else { return false }
        if let dispatch {
            let tr = state.tr
            guard (try? tr.replaceRange(from, to, trimmed(ring.entries[index]))) != nil else { return false }
            let start = tr.mapping.map(from, assoc: -1), end = tr.selection.to
            dispatch(tr.setMeta(key, Meta.yank(from: start, to: end, index: index)).setActionName("Yank").scrollIntoView())
        }
        return true
    }

    /// Inserts the latest entry over the selection.
    public static let yank: Command = { state, dispatch, _ in
        insert(state, 0, from: state.selection.from, to: state.selection.to, dispatch)
    }

    /// Right after a yank, replaces the yanked content with the next older entry.
    public static let yankPop: Command = { state, dispatch, _ in
        guard let ring = key.getState(state), let last = ring.lastYank, ring.entries.count > 1 else { return false }
        return insert(state, (last.index + 1) % ring.entries.count, from: last.from, to: last.to, dispatch)
    }

    /// Emacs key bindings for the kill ring.
    public static let keymap: [String: Command] = [
        "Ctrl-k": killToEndOfTextblock,
        "Ctrl-w": killRegion,
        "Ctrl-y": yank,
        "Alt-y": yankPop,
    ]
}
