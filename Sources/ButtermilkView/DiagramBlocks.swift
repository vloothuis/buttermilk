import ButtermilkCore
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// How serious a ``DiagramDiagnostic`` is. ``Theme/diagnosticColors`` maps it to a color.
public enum DiagnosticSeverity: Hashable {
    case error, warning, info
}

/// A problem in a diagram's source, with its range in UTF-16 code units.
public struct DiagramDiagnostic: Equatable {
    public var range: NSRange
    public var severity: DiagnosticSeverity
    public var message: String
    public init(_ range: NSRange, _ severity: DiagnosticSeverity, _ message: String) {
        self.range = range; self.severity = severity; self.message = message
    }
}

/// Checks a diagram's source. The editor calls it after each change, on the main thread, so it
/// should be fast.
public protocol DiagramLinter {
    func diagnostics(in source: String, language: String) -> [DiagramDiagnostic]
}

/// Suggests words to complete the partial word `prefix` that ends at `offset` in `source`.
public protocol DiagramCompleter {
    func completions(for prefix: String, in source: String, at offset: Int, language: String) -> [String]
}

/// Settings for diagram blocks: code blocks whose language is a diagram language. Each one is
/// edited in an embedded code editor (a ``DiagramEditor`` node view) with syntax highlighting,
/// completions and lint diagnostics. Call ``install(on:)`` to turn it on.
public struct DiagramBlocks {
    /// Diagram languages, lowercased.
    public var languages: Set<String>
    public var completer: DiagramCompleter?
    public var linter: DiagramLinter?
    /// Highlights the source; nil uses the editor's renderer highlighter.
    public var highlighter: SyntaxHighlighter?
    /// The code block node type name.
    public var nodeType = "code_block"

    public init(languages: Set<String> = ["mermaid", "plantuml", "d2"], completer: DiagramCompleter? = nil,
                linter: DiagramLinter? = nil, highlighter: SyntaxHighlighter? = nil) {
        self.languages = Set(languages.map { $0.lowercased() })
        self.completer = completer; self.linter = linter; self.highlighter = highlighter
    }

    /// The language of a code block, lowercased.
    public static func language(of node: Node) -> String {
        (node.attrs["language"]?.stringValue ?? node.attrs["params"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    public func isDiagram(_ node: Node) -> Bool {
        node.type.name == nodeType && languages.contains(Self.language(of: node))
    }

    /// Makes diagram blocks in `core` render as ``DiagramEditor``s. It replaces any node view
    /// filter and any node view for ``nodeType``.
    public func install(on core: EditorCore) {
        let config = self
        core.nodeViewFilter = { $0.type.name != config.nodeType || config.isDiagram($0) }
        core.nodeViews[nodeType] = { [weak core] node, view, getPos in
            DiagramEditor(node, view, getPos, config: config, core: core)
        }
    }

    /// Styles `text`, the diagram source, in place: code font, highlighting and diagnostics.
    func style(_ text: NSMutableAttributedString, language: String, theme: Theme,
               fallback: SyntaxHighlighter?) -> [DiagramDiagnostic] {
        let all = NSRange(location: 0, length: text.length)
        text.setAttributes([.font: theme.codeFont, .foregroundColor: theme.textColor], range: all)
        let source = text.string
        for token in (highlighter ?? fallback)?.tokens(in: source, language: language) ?? [] {
            guard let color = theme.syntaxColors[token.kind] else { continue }
            let range = NSIntersectionRange(token.range, all)
            if range.length > 0 { text.addAttribute(.foregroundColor, value: color, range: range) }
        }
        let diagnostics = linter?.diagnostics(in: source, language: language) ?? []
        for d in diagnostics {
            var range = NSIntersectionRange(d.range, all)
            // An empty range marks the character after it, or the last one.
            if range.length == 0, text.length > 0 { range = NSRange(location: min(d.range.location, text.length - 1), length: 1) }
            guard range.length > 0, range.location >= 0 else { continue }
            text.addAttributes([
                .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue | NSUnderlineStyle.thick.rawValue,
                .underlineColor: theme.diagnosticColors[d.severity] ?? theme.secondaryColor,
                .buttermilkDiagnostic: d.message,
            ], range: range)
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            text.addAttribute(.toolTip, value: d.message, range: range)
            #endif
        }
        return diagnostics
    }

    /// The partial word before `offset` and the completions for it.
    func completions(in source: String, at offset: Int, language: String) -> (range: NSRange, words: [String]) {
        let s = source as NSString
        var start = min(offset, s.length)
        while start > 0, let scalar = Unicode.Scalar(s.character(at: start - 1)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" { start -= 1 }
        let range = NSRange(location: start, length: min(offset, s.length) - start)
        let words = completer?.completions(for: s.substring(with: range), in: source, at: offset, language: language) ?? []
        return (range, words)
    }

    /// A transaction that sets the content of the code block at `pos` to `source`, or nil when
    /// it already has that content.
    static func sourceTransaction(_ state: EditorState, pos: Int, source: String) -> Transaction? {
        guard let node = state.doc.nodeAt(pos), node.textContent != source else { return nil }
        let content = source.isEmpty ? Fragment.empty : Fragment.from(state.schema.text(source))
        return try? state.tr.replaceWith(pos + 1, pos + node.nodeSize - 1, content)
    }
}

public extension NSAttributedString.Key {
    /// The message of a lint diagnostic, on the source it covers in a ``DiagramEditor``.
    static let buttermilkDiagnostic = NSAttributedString.Key("ButtermilkDiagnostic")
}
