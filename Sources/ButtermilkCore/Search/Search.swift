import Foundation

/// A search query, as `SearchQuery` in `prosemirror-search`. Matches never cross textblock
/// boundaries. Inline nodes other than text count as one object replacement character each.
public struct SearchQuery {
    public let search: String
    public let caseSensitive: Bool
    /// When false (and not a regular expression), `\n`, `\r`, `\t` and `\\` in ``search`` and
    /// ``replace`` stand for a newline, return, tab and backslash.
    public let literal: Bool
    public let regexp: Bool
    /// The replacement text. In regular expression mode, `$&` is the match, `$1`... are groups
    /// and `$$` is a dollar sign.
    public let replace: String
    public let wholeWord: Bool
    /// Rejects matches the predicate returns false for.
    public let filter: ((EditorState, SearchResult) -> Bool)?

    /// True when the search string is not empty and, in regular expression mode, compiles.
    public var valid: Bool { regex != nil }
    let regex: NSRegularExpression?
    let unquotedReplace: String

    public init(search: String, caseSensitive: Bool = false, literal: Bool = false, regexp: Bool = false,
                replace: String = "", wholeWord: Bool = false, filter: ((EditorState, SearchResult) -> Bool)? = nil) {
        self.search = search; self.caseSensitive = caseSensitive; self.literal = literal; self.regexp = regexp
        self.replace = replace; self.wholeWord = wholeWord; self.filter = filter
        let unquote = !literal && !regexp
        unquotedReplace = unquote ? Self.unquote(replace) : replace
        let pattern = regexp ? search : NSRegularExpression.escapedPattern(for: unquote ? Self.unquote(search) : search)
        regex = search.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    static func unquote(_ s: String) -> String {
        var out = "", escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(c)
                }
                escaped = false
            } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// Whether two queries search and replace the same way. Filters are not compared.
    public func eq(_ other: SearchQuery) -> Bool {
        search == other.search && replace == other.replace && caseSensitive == other.caseSensitive
            && regexp == other.regexp && literal == other.literal && wholeWord == other.wholeWord
    }

    /// The first match that starts at or after `from` and ends at or before `to`.
    public func findNext(_ state: EditorState, _ from: Int = 0, _ to: Int? = nil) -> SearchResult? {
        let to = to ?? state.doc.content.size
        var found: SearchResult?
        forEachBlock(state.doc, from, to) { start, text in
            for r in matches(state, start, text) where r.from >= from && r.to <= to {
                found = r; return false
            }
            return true
        }
        return found
    }

    /// The last match that ends at or before `from` and starts at or after `to`.
    public func findPrev(_ state: EditorState, _ from: Int? = nil, _ to: Int = 0) -> SearchResult? {
        let from = from ?? state.doc.content.size
        var found: SearchResult?
        forEachBlock(state.doc, to, from, reverse: true) { start, text in
            if let r = matches(state, start, text).last(where: { $0.to <= from && $0.from >= to }) { found = r; return false }
            return true
        }
        return found
    }

    /// All matches in `from..<to`, in document order.
    public func findAll(_ state: EditorState, _ from: Int = 0, _ to: Int? = nil) -> [SearchResult] {
        let to = to ?? state.doc.content.size
        var out: [SearchResult] = []
        forEachBlock(state.doc, from, to) { start, text in
            out += matches(state, start, text).filter { $0.from >= from && $0.to <= to }
            return true
        }
        return out
    }

    /// The text that replaces `result`.
    public func replacement(for result: SearchResult) -> String {
        guard regexp, let regex else { return unquotedReplace }
        return regex.replacementString(for: result.match, in: result.blockText as String, offset: 0,
                                       template: Self.template(unquotedReplace))
    }

    /// Converts the `$&`/`$1`/`$$` syntax to an `NSRegularExpression` template.
    static func template(_ s: String) -> String {
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "$", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "&" { out += "$0"; i += 2; continue }
                if n == "$" { out += "\\$"; i += 2; continue }
                if n.isNumber { out += "$"; i += 1; continue }
                out += "\\$"; i += 1; continue
            }
            if c == "$" { out += "\\$" } else if c == "\\" { out += "\\\\" } else { out.append(c) }
            i += 1
        }
        return out
    }

    func matches(_ state: EditorState, _ start: Int, _ text: NSString) -> [SearchResult] {
        guard let regex else { return [] }
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).compactMap { m in
            if m.range.length == 0 { return nil }
            if wholeWord, !Self.isWordBoundary(text, m.range) { return nil }
            let r = SearchResult(from: start + m.range.location, to: start + m.range.location + m.range.length,
                                 match: m, matchStart: start, blockText: text)
            return filter?(state, r) ?? true ? r : nil
        }
    }

    static func isWordBoundary(_ text: NSString, _ range: NSRange) -> Bool {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let s = UnicodeScalar(text.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(s) || s == "_"
        }
        return !(isWord(range.location - 1) && isWord(range.location)) && !(isWord(NSMaxRange(range) - 1) && isWord(NSMaxRange(range)))
    }

    /// Calls `f` with the content start and text of each textblock touching `from...to`.
    /// Stops when `f` returns false.
    func forEachBlock(_ doc: Node, _ from: Int, _ to: Int, reverse: Bool = false, _ f: (Int, NSString) -> Bool) {
        var blocks: [(Int, Node)] = []
        doc.nodesBetween(from, to) { node, pos, _, _ in
            if node.isTextblock { blocks.append((pos + 1, node)); return false }
            return true
        }
        if reverse { blocks.reverse() }
        for (start, node) in blocks {
            var text = ""
            node.forEach { child, _, _ in
                text += child.text ?? String(repeating: "\u{FFFC}", count: child.nodeSize)
            }
            if !f(start, text as NSString) { return }
        }
    }
}

/// A match found by a ``SearchQuery``.
public struct SearchResult {
    public let from: Int
    public let to: Int
    /// The regular expression match, with ranges relative to ``matchStart``.
    public let match: NSTextCheckingResult
    /// The document position the textblock's text starts at.
    public let matchStart: Int
    let blockText: NSString

    /// The matched text, or the text of capture group `group`.
    public func group(_ group: Int) -> String? {
        guard group < match.numberOfRanges, match.range(at: group).location != NSNotFound else { return nil }
        return blockText.substring(with: match.range(at: group))
    }
}

/// The search plugin and commands, as `prosemirror-search`.
///
/// The plugin keeps a query and an optional range, and highlights matches with inline
/// decorations. The match equal to the selection gets ``Options/activeMatchAttributes``.
public enum Search {
    public struct State {
        public let query: SearchQuery
        /// The range searched, or nil for the whole document. It is mapped through changes.
        public let range: (from: Int, to: Int)?
        public let decorations: DecorationSet
    }

    public struct Options {
        public var initialQuery: SearchQuery?
        public var initialRange: (from: Int, to: Int)?
        /// Attributes of every match. Pass for example a background color.
        public var matchAttributes: DecorationAttributes
        /// Attributes of the match at the selection.
        public var activeMatchAttributes: DecorationAttributes
        public init(initialQuery: SearchQuery? = nil, initialRange: (from: Int, to: Int)? = nil,
                    matchAttributes: DecorationAttributes = [.searchMatch: true],
                    activeMatchAttributes: DecorationAttributes = [.searchMatch: true, .activeSearchMatch: true]) {
            self.initialQuery = initialQuery; self.initialRange = initialRange
            self.matchAttributes = matchAttributes; self.activeMatchAttributes = activeMatchAttributes
        }
    }

    static let key = PluginKey<State>("search")

    struct Meta { let query: SearchQuery; let range: (from: Int, to: Int)? }

    public static func plugin(_ options: Options = .init()) -> Plugin {
        Plugin(key: key,
               state: StateField<State>(
                   initialize: { _, state in
                       let query = options.initialQuery ?? SearchQuery(search: "")
                       return State(query: query, range: options.initialRange,
                                    decorations: buildDecorations(state, query, options.initialRange, options))
                   },
                   apply: { tr, search, _, state in
                       if let meta = tr.getMeta(key, as: Meta.self) {
                           return State(query: meta.query, range: meta.range,
                                        decorations: buildDecorations(state, meta.query, meta.range, options))
                       }
                       guard tr.docChanged || tr.selectionSet else { return search }
                       var range = search.range
                       if tr.docChanged, let r = range {
                           range = (tr.mapping.map(r.from, assoc: 1), tr.mapping.map(r.to, assoc: -1))
                       }
                       return State(query: search.query, range: range,
                                    decorations: buildDecorations(state, search.query, range, options))
                   }),
               props: { var p = EditorProps(); p.decorations = { key.getState($0)?.decorations ?? .empty }; return p }())
    }

    static func buildDecorations(_ state: EditorState, _ query: SearchQuery, _ range: (from: Int, to: Int)?,
                                 _ options: Options) -> DecorationSet {
        guard query.valid else { return .empty }
        let sel = state.selection
        let decos = query.findAll(state, range?.from ?? 0, range?.to).map { r -> Decoration in
            let active = r.from == sel.from && r.to == sel.to
            return .inline(r.from, r.to, active ? options.activeMatchAttributes : options.matchAttributes,
                           spec: ["searchMatch": true, "active": active])
        }
        return DecorationSet.create(state.doc, decos)
    }

    /// The plugin state, or nil without the plugin.
    public static func getState(_ state: EditorState) -> State? { key.getState(state) }

    /// The match decorations.
    public static func getMatchHighlights(_ state: EditorState) -> DecorationSet { key.getState(state)?.decorations ?? .empty }

    /// Sets the query and range on a transaction.
    @discardableResult
    public static func setSearchState(_ tr: Transaction, _ query: SearchQuery, range: (from: Int, to: Int)? = nil) -> Transaction {
        tr.setMeta(key, Meta(query: query, range: range))
    }

    static func active(_ state: EditorState) -> (State, from: Int, to: Int)? {
        guard let s = key.getState(state), s.query.valid else { return nil }
        return (s, s.range?.from ?? 0, s.range?.to ?? state.doc.content.size)
    }

    static func next(_ state: EditorState, _ s: State, _ from: Int, _ to: Int, wrap: Bool) -> SearchResult? {
        let start = state.selection.to
        return s.query.findNext(state, max(start, from), to) ?? (wrap ? s.query.findNext(state, from, min(start, to)) : nil)
    }

    static func prev(_ state: EditorState, _ s: State, _ from: Int, _ to: Int, wrap: Bool) -> SearchResult? {
        let start = state.selection.from
        return s.query.findPrev(state, min(start, to), from) ?? (wrap ? s.query.findPrev(state, to, max(start, from)) : nil)
    }

    static func select(_ result: SearchResult, _ state: EditorState, _ dispatch: ((Transaction) -> Void)?) -> Bool {
        dispatch?(state.tr.setSelection(TextSelection.create(state.doc, result.from, result.to)).scrollIntoView())
        return true
    }

    static func findCommand(wrap: Bool, forward: Bool) -> Command {
        return { state, dispatch, _ in
            guard let (s, from, to) = active(state),
                  let r = forward ? next(state, s, from, to, wrap: wrap) : prev(state, s, from, to, wrap: wrap) else { return false }
            return select(r, state, dispatch)
        }
    }

    /// Selects the next match, wrapping to the start.
    public static let findNext: Command = findCommand(wrap: true, forward: true)
    public static let findNextNoWrap: Command = findCommand(wrap: false, forward: true)
    /// Selects the previous match, wrapping to the end.
    public static let findPrev: Command = findCommand(wrap: true, forward: false)
    public static let findPrevNoWrap: Command = findCommand(wrap: false, forward: false)

    static func replace(_ tr: Transaction, _ state: EditorState, _ query: SearchQuery, _ r: SearchResult) throws {
        let text = query.replacement(for: r)
        let marks = state.doc.resolve(r.from).marksAcross(state.doc.resolve(r.to)) ?? []
        if text.isEmpty { try tr.delete(r.from, r.to) } else { try tr.replaceWith(r.from, r.to, state.schema.text(text, marks: marks)) }
    }

    /// The match at the selection, if the selection covers exactly one.
    static func current(_ state: EditorState, _ s: State, _ from: Int, _ to: Int) -> SearchResult? {
        let sel = state.selection
        guard let r = s.query.findNext(state, max(sel.from, from), to), r.from == sel.from, r.to == sel.to else { return nil }
        return r
    }

    static func replaceCommand(wrap: Bool, moveForward: Bool) -> Command {
        return { state, dispatch, _ in
            guard let (s, from, to) = active(state) else { return false }
            guard let r = current(state, s, from, to) else {
                // Nothing selected yet: select the next match first, as prosemirror-search does.
                guard moveForward, let n = next(state, s, from, to, wrap: wrap) else { return false }
                return select(n, state, dispatch)
            }
            guard let dispatch else { return true }
            let tr = state.tr
            do { try replace(tr, state, s.query, r) } catch { return false }
            let end = tr.mapping.map(r.to, assoc: 1)
            if moveForward, let after = try? state.apply(tr), let n = nextAfter(after, s.query, end, wrap: wrap) {
                tr.setSelection(TextSelection.create(tr.doc, n.from, n.to))
            } else {
                tr.setSelection(TextSelection.create(tr.doc, end))
            }
            dispatch(tr.setActionName("Replace").scrollIntoView())
            return true
        }
    }

    static func nextAfter(_ state: EditorState, _ query: SearchQuery, _ pos: Int, wrap: Bool) -> SearchResult? {
        guard let s = key.getState(state) else { return nil }
        let from = s.range?.from ?? 0, to = s.range?.to ?? state.doc.content.size
        return query.findNext(state, max(pos, from), to) ?? (wrap ? query.findNext(state, from, min(pos, to)) : nil)
    }

    /// Replaces the selected match and selects the next one. When the selection is not a match,
    /// selects the next match.
    public static let replaceNext: Command = replaceCommand(wrap: true, moveForward: true)
    public static let replaceNextNoWrap: Command = replaceCommand(wrap: false, moveForward: true)
    /// Replaces the selected match and leaves the cursor after it.
    public static let replaceCurrent: Command = replaceCommand(wrap: false, moveForward: false)

    /// Replaces all matches in the search range.
    public static let replaceAll: Command = { state, dispatch, _ in
        guard let (s, from, to) = active(state) else { return false }
        let matches = s.query.findAll(state, from, to)
        guard !matches.isEmpty else { return false }
        guard let dispatch else { return true }
        let tr = state.tr
        do { for r in matches.reversed() { try replace(tr, state, s.query, r) } } catch { return false }
        dispatch(tr.setActionName("Replace All").scrollIntoView())
        return true
    }
}

public extension NSAttributedString.Key {
    /// Set on search matches by the default ``Search/Options``.
    static let searchMatch = NSAttributedString.Key("ButtermilkSearchMatch")
    /// Set on the match at the selection by the default ``Search/Options``.
    static let activeSearchMatch = NSAttributedString.Key("ButtermilkActiveSearchMatch")
}
