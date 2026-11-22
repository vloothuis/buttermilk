import Foundation

/// The result of matching an input rule. Offsets and lengths count UTF-16 code units.
public struct InputRuleMatch {
    /// The full match (index 0) and the capture groups. Groups that did not take part are nil.
    public let groups: [String?]
    public subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    /// The full matched text.
    public var text: String { groups[0] ?? "" }
}

/// A rule that runs when the text before the cursor matches a pattern after typing.
public struct InputRule {
    public typealias Handler = (_ state: EditorState, _ match: InputRuleMatch, _ start: Int, _ end: Int, _ text: String) -> Transaction?

    /// Where a rule applies with respect to code.
    public enum CodeMode { case outside, anywhere, only }

    public let regex: NSRegularExpression
    public let handler: Handler
    /// Whether ``InputRules/undoInputRule`` can revert the rule.
    public var undoable: Bool
    /// Whether the rule applies in code blocks (`spec.code` nodes).
    public var inCode: CodeMode
    /// Whether the rule applies inside marks with `spec.code`.
    public var inCodeMark: Bool

    /// Create a rule from a regular expression (ICU syntax, which covers the JS patterns that input
    /// rules use). The pattern should end with `$`.
    public init(_ pattern: String, undoable: Bool = true, inCode: CodeMode = .outside, inCodeMark: Bool = true,
                handler: @escaping Handler) {
        self.init(try! NSRegularExpression(pattern: pattern), undoable: undoable, inCode: inCode,
                  inCodeMark: inCodeMark, handler: handler)
    }

    public init(_ regex: NSRegularExpression, undoable: Bool = true, inCode: CodeMode = .outside, inCodeMark: Bool = true,
                handler: @escaping Handler) {
        self.regex = regex; self.handler = handler
        self.undoable = undoable; self.inCode = inCode; self.inCodeMark = inCodeMark
    }

    /// A rule that replaces the matched text with `replacement`. When the pattern has a capture
    /// group, only the text of the first group is replaced.
    public init(_ pattern: String, replacement: String, undoable: Bool = true, inCode: CodeMode = .outside,
                inCodeMark: Bool = true) {
        self.init(pattern, undoable: undoable, inCode: inCode, inCodeMark: inCodeMark) { state, match, start, end, _ in
            var insert = replacement as NSString
            var start = start
            if let g1 = match[1], !g1.isEmpty {
                let m0 = match.text as NSString
                let offset = m0.range(of: g1, options: .backwards).location
                insert = insert.appending(m0.substring(from: offset + (g1 as NSString).length)) as NSString
                start += offset
                let cutOff = start - end
                if cutOff > 0 {
                    insert = (m0.substring(with: NSRange(location: offset - cutOff, length: cutOff)) + (insert as String)) as NSString
                    start = end
                }
            }
            return try? state.tr.insertText(insert as String, start, end)
        }
    }

    func match(_ text: String) -> InputRuleMatch? {
        let ns = text as NSString
        guard let r = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups: [String?] = (0..<r.numberOfRanges).map { i in
            let range = r.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        return InputRuleMatch(groups: groups)
    }
}

/// The state of an input rules plugin: the last applied undoable rule.
public struct InputRuleUndo {
    public let transform: Transaction
    public let from: Int, to: Int
    public let text: String
}

public enum InputRules {
    static let maxMatch = 500

    /// A plugin that runs the rules on text input.
    public static func plugin(_ rules: [InputRule]) -> Plugin {
        let key = PluginKey<InputRuleUndo?>("inputRules")
        var props = EditorProps()
        props.handleTextInput = { view, from, to, text in
            run(view, from, to, text, rules, key)
        }
        return Plugin(key: key,
                      state: StateField<InputRuleUndo?>(
                          initialize: { _, _ in nil },
                          apply: { tr, prev, _, _ in
                              if let stored = tr.getMeta(key, as: InputRuleUndo.self) { return stored }
                              return tr.selectionSet || tr.docChanged ? nil : prev
                          }),
                      props: props,
                      extra: ["isInputRules": true])
    }

    /// Run the rules after `text` is typed over `from..<to`. Returns true when a rule applied.
    /// The view calls this through `handleTextInput`; it is public for views that end a composition.
    @discardableResult
    public static func run(_ view: EditorViewing, _ from: Int, _ to: Int, _ text: String, _ rules: [InputRule],
                           _ key: PluginKey<InputRuleUndo?>) -> Bool {
        if view.composing { return false }
        let state = view.state, rFrom = state.doc.resolve(from), sel = state.selection
        let textBefore = rFrom.parent.textBetween(Swift.max(0, rFrom.parentOffset - maxMatch), rFrom.parentOffset,
                                                  blockSeparator: nil, leafText: { _ in "\u{fffc}" }) + text
        let stored = from == sel.from && to == sel.to ? state.storedMarks : nil
        let marks = stored ?? (from == to ? rFrom.marks() : rFrom.marksAcross(state.doc.resolve(to)) ?? [])
        let textLength = text.utf16.count
        for rule in rules {
            if !rule.inCodeMark && marks.contains(where: { $0.type.spec.code }) { continue }
            if rFrom.parent.type.spec.code {
                if rule.inCode == .outside { continue }
            } else if rule.inCode == .only {
                continue
            }
            guard let match = rule.match(textBefore), match.text.utf16.count >= textLength else { continue }
            let startPos = from - (match.text.utf16.count - textLength)
            if !rule.inCodeMark {
                var hasMark = false
                state.doc.nodesBetween(startPos, rFrom.pos) { node, _, _, _ in
                    if node.isInline && node.marks.contains(where: { $0.type.spec.code }) { hasMark = true }
                    return true
                }
                if hasMark { continue }
            }
            guard let tr = rule.handler(state, match, startPos, to, text) else { continue }
            if rule.undoable { tr.setMeta(key, InputRuleUndo(transform: tr, from: from, to: to, text: text)) }
            view.dispatch(tr)
            return true
        }
        return false
    }

    /// Undo the input rule that was applied last, if the user has not done anything else since.
    public static let undoInputRule: Command = { state, dispatch, _ in
        for plugin in state.plugins where plugin.extra["isInputRules"] as? Bool == true {
            guard let undoable = plugin.getState(state, as: InputRuleUndo?.self) ?? nil else { continue }
            if let dispatch {
                do {
                    let tr = state.tr, toUndo = undoable.transform
                    for j in stride(from: toUndo.steps.count - 1, through: 0, by: -1) {
                        try tr.step(toUndo.steps[j].invert(toUndo.docs[j]))
                    }
                    if !undoable.text.isEmpty {
                        let marks = tr.doc.resolve(undoable.from).marks()
                        try tr.replaceWith(undoable.from, undoable.to, state.schema.text(undoable.text, marks: marks))
                    } else {
                        try tr.delete(undoable.from, undoable.to)
                    }
                    dispatch(tr)
                } catch { return false }
            }
            return true
        }
        return false
    }

    // MARK: Rule builders

    /// A rule that wraps the textblock in a node of `nodeType` when the pattern matches at its start.
    public static func wrappingRule(_ pattern: String, _ nodeType: NodeType,
                                    attrs: ((InputRuleMatch) -> Attrs?)? = nil,
                                    joinPredicate: ((InputRuleMatch, Node) -> Bool)? = nil,
                                    undoable: Bool = true) -> InputRule {
        InputRule(pattern, undoable: undoable) { state, match, start, end, _ in
            let a = attrs?(match)
            guard let tr = try? state.tr.delete(start, end) else { return nil }
            let rStart = tr.doc.resolve(start)
            guard let range = rStart.blockRange(), let wrapping = findWrapping(range, nodeType, attrs: a),
                  (try? tr.wrap(range, wrapping)) != nil else { return nil }
            if let before = tr.doc.resolve(start - 1).nodeBefore, before.type === nodeType, canJoin(tr.doc, start - 1),
               joinPredicate?(match, before) ?? true {
                _ = try? tr.join(start - 1)
            }
            return tr
        }
    }

    /// A rule that changes the textblock type when the pattern matches at its start.
    public static func textblockTypeRule(_ pattern: String, _ nodeType: NodeType,
                                         attrs: ((InputRuleMatch) -> Attrs?)? = nil,
                                         undoable: Bool = true) -> InputRule {
        InputRule(pattern, undoable: undoable) { state, match, start, end, _ in
            let rStart = state.doc.resolve(start)
            let a = attrs?(match)
            if !rStart.node(-1).canReplaceWith(rStart.index(-1), rStart.indexAfter(-1), nodeType) { return nil }
            return try? state.tr.delete(start, end).setBlockType(start, start, nodeType, attrs: a)
        }
    }

    // MARK: Typographic rules

    public static let emDash = InputRule("--$", replacement: "—", inCodeMark: false)
    public static let ellipsis = InputRule("\\.\\.\\.$", replacement: "…", inCodeMark: false)
    public static let openDoubleQuote = smartQuotes(QuoteCharacters())[0]
    public static let closeDoubleQuote = smartQuotes(QuoteCharacters())[1]
    public static let openSingleQuote = smartQuotes(QuoteCharacters())[2]
    public static let closeSingleQuote = smartQuotes(QuoteCharacters())[3]
    /// The four quote rules with English curly quotes.
    public static let smartQuotes = smartQuotes(QuoteCharacters())

    /// The characters that the smart quote rules insert.
    public struct QuoteCharacters {
        public var openDouble: String, closeDouble: String, openSingle: String, closeSingle: String
        public init(openDouble: String = "“", closeDouble: String = "”", openSingle: String = "‘", closeSingle: String = "’") {
            self.openDouble = openDouble; self.closeDouble = closeDouble
            self.openSingle = openSingle; self.closeSingle = closeSingle
        }
    }

    /// The rules openDoubleQuote, closeDoubleQuote, openSingleQuote and closeSingleQuote, in that
    /// order, with the given characters. A quote opens at the start of a textblock or after
    /// whitespace, an opening bracket or another quote.
    public static func smartQuotes(_ q: QuoteCharacters) -> [InputRule] {
        let before = NSRegularExpression.escapedPattern(for: "{[(<'\"" + q.openSingle + q.openDouble)
        return [
            InputRule("(?:^|[\\s\(before)])(\")$", replacement: q.openDouble, inCodeMark: false),
            InputRule("\"$", replacement: q.closeDouble, inCodeMark: false),
            InputRule("(?:^|[\\s\(before)])(')$", replacement: q.openSingle, inCodeMark: false),
            InputRule("'$", replacement: q.closeSingle, inCodeMark: false),
        ]
    }
}
