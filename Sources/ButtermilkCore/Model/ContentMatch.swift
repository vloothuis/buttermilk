/// A state in the finite automaton compiled from a node type's content expression.
public final class ContentMatch: CustomStringConvertible {
    public struct Edge {
        public let type: NodeType
        public let next: ContentMatch
    }

    public let validEnd: Bool
    public internal(set) var next: [Edge] = []
    private var wrapCache: [(NodeType, [NodeType]?)] = []

    init(validEnd: Bool) { self.validEnd = validEnd }

    public static let empty = ContentMatch(validEnd: true)
    /// A match that accepts nothing and is not a valid end.
    static let dead = ContentMatch(validEnd: false)

    static func parse(_ string: String, nodeTypes: [NodeType], byName: [String: NodeType]) throws -> ContentMatch {
        let stream = TokenStream(string: string, nodeTypes: nodeTypes, byName: byName)
        if stream.next == nil { return .empty }
        let expr = try parseExpr(stream)
        if stream.next != nil { throw stream.err("Unexpected trailing text") }
        let match = dfa(nfa(expr))
        try checkForDeadEnds(match, stream)
        return match
    }

    public func matchType(_ type: NodeType) -> ContentMatch? {
        for e in next where e.type === type { return e.next }
        return nil
    }

    public func matchFragment(_ frag: Fragment, start: Int = 0, end: Int? = nil) -> ContentMatch? {
        let end = end ?? frag.childCount
        var cur: ContentMatch? = self
        var i = start
        while let c = cur, i < end {
            cur = c.matchType(frag.child(i).type)
            i += 1
        }
        return cur
    }

    public var inlineContent: Bool { !next.isEmpty && next[0].type.isInline }

    public var defaultType: NodeType? {
        next.first { !($0.type.isText || $0.type.hasRequiredAttrs()) }?.type
    }

    public func compatible(_ other: ContentMatch) -> Bool {
        for a in next { for b in other.next where a.type === b.type { return true } }
        return false
    }

    /// Find a set of nodes that, when inserted before `after`, make the content valid.
    public func fillBefore(_ after: Fragment, toEnd: Bool = false, startIndex: Int = 0) -> Fragment? {
        var seen: [ContentMatch] = [self]
        func search(_ match: ContentMatch, _ types: [NodeType]) -> Fragment? {
            if let finished = match.matchFragment(after, start: startIndex), !toEnd || finished.validEnd {
                return Fragment.from(types.map { $0.createAndFill()! })
            }
            for e in match.next where !(e.type.isText || e.type.hasRequiredAttrs()) && !seen.contains(where: { $0 === e.next }) {
                seen.append(e.next)
                if let found = search(e.next, types + [e.type]) { return found }
            }
            return nil
        }
        return search(self, [])
    }

    /// Find the node types that must be wrapped around a node of `target` type to make it fit here.
    public func findWrapping(_ target: NodeType) -> [NodeType]? {
        for (t, w) in wrapCache where t === target { return w }
        let computed = computeWrapping(target)
        wrapCache.append((target, computed))
        return computed
    }

    private func computeWrapping(_ target: NodeType) -> [NodeType]? {
        final class Active {
            let match: ContentMatch; let type: NodeType?; let via: Active?
            init(_ m: ContentMatch, _ t: NodeType?, _ v: Active?) { match = m; type = t; via = v }
        }
        var seen = Set<String>()
        var active = [Active(self, nil, nil)]
        var head = 0
        while head < active.count {
            let current = active[head]; head += 1
            let match = current.match
            if match.matchType(target) != nil {
                var result: [NodeType] = []
                var obj: Active? = current
                while let o = obj, let t = o.type { result.append(t); obj = o.via }
                return result.reversed()
            }
            for e in match.next {
                let type = e.type
                if !type.isLeaf && !type.hasRequiredAttrs() && !seen.contains(type.name)
                    && (current.type == nil || e.next.validEnd) {
                    active.append(Active(type.contentMatch, type, current))
                    seen.insert(type.name)
                }
            }
        }
        return nil
    }

    public var edgeCount: Int { next.count }

    public func edge(_ n: Int) -> Edge {
        precondition(n < next.count, "There's no \(n)th edge in this content match")
        return next[n]
    }

    public var description: String {
        var seen: [ContentMatch] = []
        func scan(_ m: ContentMatch) {
            seen.append(m)
            for e in m.next where !seen.contains(where: { $0 === e.next }) { scan(e.next) }
        }
        scan(self)
        return seen.enumerated().map { i, m in
            var out = "\(i)\(m.validEnd ? "*" : " ") "
            out += m.next.enumerated().map { j, e in
                "\(e.type.name)->\(seen.firstIndex { $0 === e.next }!)"
            }.joined(separator: ", ")
            return out
        }.joined(separator: "\n")
    }
}

// MARK: - Content expression parsing

private final class TokenStream {
    var inline: Bool?
    var pos = 0
    let tokens: [String]
    let string: String
    let nodeTypes: [NodeType]
    let byName: [String: NodeType]

    init(string: String, nodeTypes: [NodeType], byName: [String: NodeType]) {
        self.string = string
        self.nodeTypes = nodeTypes
        self.byName = byName
        var tokens: [String] = []
        var chars = Array(string)
        var i = 0
        func isWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if isWord(c) {
                var j = i
                while j < chars.count, isWord(chars[j]) { j += 1 }
                tokens.append(String(chars[i..<j]))
                i = j
            } else {
                tokens.append(String(c))
                i += 1
            }
        }
        chars = []
        self.tokens = tokens
    }

    var next: String? { pos < tokens.count ? tokens[pos] : nil }

    func eat(_ tok: String) -> Bool {
        if next == tok { pos += 1; return true }
        return false
    }

    func err(_ str: String) -> ProseError {
        .syntax("\(str) (in content expression '\(string)')")
    }
}

private indirect enum Expr {
    case choice([Expr]), seq([Expr]), plus(Expr), star(Expr), opt(Expr)
    case range(min: Int, max: Int, Expr)
    case name(NodeType)
}

private func parseExpr(_ stream: TokenStream) throws -> Expr {
    var exprs: [Expr] = []
    repeat { exprs.append(try parseExprSeq(stream)) } while stream.eat("|")
    return exprs.count == 1 ? exprs[0] : .choice(exprs)
}

private func parseExprSeq(_ stream: TokenStream) throws -> Expr {
    var exprs: [Expr] = []
    repeat { exprs.append(try parseExprSubscript(stream)) }
    while stream.next != nil && stream.next != ")" && stream.next != "|"
    return exprs.count == 1 ? exprs[0] : .seq(exprs)
}

private func parseExprSubscript(_ stream: TokenStream) throws -> Expr {
    var expr = try parseExprAtom(stream)
    while true {
        if stream.eat("+") { expr = .plus(expr) }
        else if stream.eat("*") { expr = .star(expr) }
        else if stream.eat("?") { expr = .opt(expr) }
        else if stream.eat("{") { expr = try parseExprRange(stream, expr) }
        else { break }
    }
    return expr
}

private func parseNum(_ stream: TokenStream) throws -> Int {
    guard let t = stream.next, let n = Int(t), t.allSatisfy(\.isNumber) else {
        throw stream.err("Expected number, got '\(stream.next ?? "")'")
    }
    stream.pos += 1
    return n
}

private func parseExprRange(_ stream: TokenStream, _ expr: Expr) throws -> Expr {
    let min = try parseNum(stream)
    var max = min
    if stream.eat(",") {
        max = stream.next != "}" ? try parseNum(stream) : -1
    }
    if !stream.eat("}") { throw stream.err("Unclosed braced range") }
    return .range(min: min, max: max, expr)
}

private func resolveName(_ stream: TokenStream, _ name: String) throws -> [NodeType] {
    if let t = stream.byName[name] { return [t] }
    let result = stream.nodeTypes.filter { $0.isInGroup(name) }
    if result.isEmpty { throw stream.err("No node type or group '\(name)' found") }
    return result
}

private func parseExprAtom(_ stream: TokenStream) throws -> Expr {
    if stream.eat("(") {
        let expr = try parseExpr(stream)
        if !stream.eat(")") { throw stream.err("Missing closing paren") }
        return expr
    }
    guard let next = stream.next, let f = next.first, f.isASCII, f.isLetter || f.isNumber || f == "_" else {
        throw stream.err("Unexpected token '\(stream.next ?? "")'")
    }
    let exprs = try resolveName(stream, next).map { type -> Expr in
        if let inline = stream.inline {
            if inline != type.isInline { throw stream.err("Mixing inline and block content") }
        } else {
            stream.inline = type.isInline
        }
        return .name(type)
    }
    stream.pos += 1
    return exprs.count == 1 ? exprs[0] : .choice(exprs)
}

// MARK: - NFA / DFA construction

private final class NFAEdge {
    let term: NodeType?
    var to: Int?
    init(term: NodeType?, to: Int?) { self.term = term; self.to = to }
}

private func nfa(_ expr: Expr) -> [[NFAEdge]] {
    var nfa: [[NFAEdge]] = [[]]
    func node() -> Int { nfa.append([]); return nfa.count - 1 }
    @discardableResult func edge(_ from: Int, _ to: Int? = nil, _ term: NodeType? = nil) -> NFAEdge {
        let e = NFAEdge(term: term, to: to)
        nfa[from].append(e)
        return e
    }
    func connect(_ edges: [NFAEdge], _ to: Int) { for e in edges { e.to = to } }
    func compile(_ expr: Expr, _ from: Int) -> [NFAEdge] {
        switch expr {
        case .choice(let exprs):
            return exprs.reduce([]) { $0 + compile($1, from) }
        case .seq(let exprs):
            var from = from
            for i in 0... {
                let next = compile(exprs[i], from)
                if i == exprs.count - 1 { return next }
                from = node()
                connect(next, from)
            }
            fatalError()
        case .star(let e):
            let loop = node()
            edge(from, loop)
            connect(compile(e, loop), loop)
            return [edge(loop)]
        case .plus(let e):
            let loop = node()
            connect(compile(e, from), loop)
            connect(compile(e, loop), loop)
            return [edge(loop)]
        case .opt(let e):
            return [edge(from)] + compile(e, from)
        case .range(let min, let max, let e):
            var cur = from
            for _ in 0..<min {
                let next = node()
                connect(compile(e, cur), next)
                cur = next
            }
            if max == -1 {
                connect(compile(e, cur), cur)
            } else if max > min {
                for _ in min..<max {
                    let next = node()
                    edge(cur, next)
                    connect(compile(e, cur), next)
                    cur = next
                }
            }
            return [edge(cur)]
        case .name(let t):
            return [edge(from, nil, t)]
        }
    }
    connect(compile(expr, 0), node())
    return nfa
}

private func nullFrom(_ nfa: [[NFAEdge]], _ node: Int) -> [Int] {
    var result: [Int] = []
    func scan(_ node: Int) {
        let edges = nfa[node]
        if edges.count == 1 && edges[0].term == nil { return scan(edges[0].to!) }
        result.append(node)
        for e in edges where e.term == nil && !result.contains(e.to!) { scan(e.to!) }
    }
    scan(node)
    return result.sorted(by: >)
}

private func dfa(_ nfa: [[NFAEdge]]) -> ContentMatch {
    var labeled: [String: ContentMatch] = [:]
    func explore(_ states: [Int]) -> ContentMatch {
        var out: [(NodeType, [Int])] = []
        for node in states {
            for e in nfa[node] {
                guard let term = e.term else { continue }
                var setIndex = out.lastIndex { $0.0 === term }
                for n in nullFrom(nfa, e.to!) {
                    if setIndex == nil { out.append((term, [])); setIndex = out.count - 1 }
                    if !out[setIndex!].1.contains(n) { out[setIndex!].1.append(n) }
                }
            }
        }
        let state = ContentMatch(validEnd: states.contains(nfa.count - 1))
        labeled[states.map(String.init).joined(separator: ",")] = state
        for (type, set) in out {
            let sorted = set.sorted(by: >)
            let key = sorted.map(String.init).joined(separator: ",")
            state.next.append(.init(type: type, next: labeled[key] ?? explore(sorted)))
        }
        return state
    }
    return explore(nullFrom(nfa, 0))
}

private func checkForDeadEnds(_ match: ContentMatch, _ stream: TokenStream) throws {
    var work = [match]
    var i = 0
    while i < work.count {
        let state = work[i]; i += 1
        var dead = !state.validEnd
        var nodes: [String] = []
        for e in state.next {
            nodes.append(e.type.name)
            if dead && !(e.type.isText || e.type.hasRequiredAttrs()) { dead = false }
            if !work.contains(where: { $0 === e.next }) { work.append(e.next) }
        }
        if dead {
            throw stream.err("Only non-generatable nodes (\(nodes.joined(separator: ", "))) in a required position (see https://prosemirror.net/docs/guide/#generatable)")
        }
    }
}
