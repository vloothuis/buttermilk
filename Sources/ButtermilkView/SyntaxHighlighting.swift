import Foundation

/// The kind of a highlighted piece of code. ``Theme/syntaxColors`` maps kinds to colors.
public enum SyntaxTokenKind: Hashable {
    case keyword, string, comment, number, type
}

/// A highlighted range of a code block's text, in UTF-16 code units.
public struct SyntaxToken: Equatable {
    public var range: NSRange
    public var kind: SyntaxTokenKind
    public init(_ range: NSRange, _ kind: SyntaxTokenKind) { self.range = range; self.kind = kind }
}

/// Finds the tokens to color in a code block. The renderer calls it with the block's text and
/// its `language` attribute (lowercased, possibly empty) each time it renders the block, which
/// only happens when the block or its decorations change.
public protocol SyntaxHighlighter {
    /// Returns the tokens of `code`, or nil when the highlighter does not know `language`.
    func tokens(in code: String, language: String) -> [SyntaxToken]?
}

/// Picks a highlighter by language, so a host can supply one per language and fall back to
/// another (by default the built-in one) for the rest.
public struct LanguageHighlighters: SyntaxHighlighter {
    public var byLanguage: [String: SyntaxHighlighter]
    public var fallback: SyntaxHighlighter?

    public init(_ byLanguage: [String: SyntaxHighlighter] = [:], fallback: SyntaxHighlighter? = BuiltinHighlighter()) {
        self.byLanguage = byLanguage.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.fallback = fallback
    }

    public func tokens(in code: String, language: String) -> [SyntaxToken]? {
        if let h = byLanguage[language] { return h.tokens(in: code, language: language) }
        return fallback?.tokens(in: code, language: language)
    }
}

/// A small lexer for a few common languages: Swift, JavaScript and TypeScript, Python, JSON,
/// shell, C and Go. It colors keywords, strings, comments, numbers and capitalized type names.
/// It does not parse, so it can miss nested constructs such as string interpolation.
public struct BuiltinHighlighter: SyntaxHighlighter {
    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (String, String)?
        var quotes: Set<Character>
        var tripleQuotes = false
        var types = true
    }

    public init() {}

    public static let languages: [String] = Array(aliases.keys).sorted()

    static let aliases: [String: String] = [
        "swift": "swift", "javascript": "js", "js": "js", "jsx": "js", "typescript": "js", "ts": "js", "tsx": "js",
        "python": "python", "py": "python", "json": "json", "sh": "shell", "bash": "shell", "shell": "shell",
        "zsh": "shell", "c": "c", "h": "c", "cpp": "c", "c++": "c", "objc": "c", "go": "go",
    ]

    static let grammars: [String: Grammar] = [
        "swift": Grammar(keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
            "internal", "let", "open", "operator", "private", "protocol", "public", "static", "struct", "subscript",
            "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for",
            "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil",
            "rethrows", "super", "self", "Self", "throw", "throws", "true", "try", "async", "await", "some", "any",
            "final", "override", "mutating", "lazy", "weak", "convenience", "required",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], tripleQuotes: true),
        "js": Grammar(keywords: [
            "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
            "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
            "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
            "void", "while", "with", "yield", "async", "await", "of", "from", "interface", "type", "enum",
            "implements", "private", "public", "protected", "readonly",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"]),
        "python": Grammar(keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
            "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self",
        ], lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true),
        "json": Grammar(keywords: ["true", "false", "null"], lineComments: [], quotes: ["\""], types: false),
        "shell": Grammar(keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
            "function", "return", "export", "local", "readonly", "echo", "exit",
        ], lineComments: ["#"], quotes: ["\"", "'"], types: false),
        "c": Grammar(keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
            "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
            "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
            "while", "bool", "true", "false", "NULL", "nullptr", "class", "namespace", "template", "public",
            "private", "protected", "new", "delete", "this",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"]),
        "go": Grammar(keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "true", "false", "nil",
        ], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"]),
    ]

    public func tokens(in code: String, language: String) -> [SyntaxToken]? {
        guard let name = Self.aliases[language], let grammar = Self.grammars[name] else { return nil }
        return Self.lex(Array(code.utf16), grammar)
    }

    static func lex(_ s: [UInt16], _ g: Grammar) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var i = 0
        let n = s.count
        func starts(_ p: String, at j: Int) -> Bool {
            let u = Array(p.utf16)
            return j + u.count <= n && Array(s[j..<j + u.count]) == u
        }
        func isIdent(_ c: UInt16) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
        }
        func emit(_ from: Int, _ to: Int, _ kind: SyntaxTokenKind) { out.append(SyntaxToken(NSRange(location: from, length: to - from), kind)) }
        let quotes = Set(g.quotes.compactMap { $0.utf16.first })
        let newline: UInt16 = 0x0A, backslash: UInt16 = 0x5C
        while i < n {
            let c = s[i]
            if let p = g.lineComments.first(where: { starts($0, at: i) }) {
                var j = i + p.utf16.count
                while j < n, s[j] != newline { j += 1 }
                emit(i, j, .comment); i = j; continue
            }
            if let (open, close) = g.blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < n, !starts(close, at: j) { j += 1 }
                j = min(n, j + close.utf16.count)
                emit(i, j, .comment); i = j; continue
            }
            if quotes.contains(c) {
                let triple = g.tripleQuotes && i + 2 < n && s[i + 1] == c && s[i + 2] == c
                var j = i + (triple ? 3 : 1)
                while j < n {
                    if s[j] == backslash { j += 2; continue }
                    if triple {
                        if j + 2 < n, s[j] == c, s[j + 1] == c, s[j + 2] == c { j += 3; break }
                    } else {
                        if s[j] == c { j += 1; break }
                        if s[j] == newline { break }
                    }
                    j += 1
                }
                j = min(j, n)
                emit(i, j, .string); i = j; continue
            }
            if c >= 0x30 && c <= 0x39, i == 0 || !isIdent(s[i - 1]) {
                var j = i + 1
                while j < n, isIdent(s[j]) || s[j] == 0x2E { j += 1 }
                emit(i, j, .number); i = j; continue
            }
            if isIdent(c) {
                var j = i + 1
                while j < n, isIdent(s[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                if g.keywords.contains(word) { emit(i, j, .keyword) }
                else if g.types, c >= 0x41 && c <= 0x5A { emit(i, j, .type) }
                i = j; continue
            }
            i += 1
        }
        return out
    }
}
