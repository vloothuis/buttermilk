#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ButtermilkCore

/// The embedded code editor of a diagram block (see ``DiagramBlocks``). It is a node view that
/// hosts its own text view. Each edit becomes a transaction that replaces the block's content.
/// Arrow keys at its first or last line (or first or last character) move the cursor back to
/// the document. Completion (Option-Escape, Control-Space) asks the ``DiagramCompleter``.
public final class DiagramEditor: NSObject, EditableNodeView, NSTextViewDelegate {
    public let textView: NSTextView
    public var view: NSView { textView }
    public private(set) var size: CGSize = .zero
    /// The diagnostics shown, from the last lint run.
    public private(set) var diagnostics: [DiagramDiagnostic] = []
    public private(set) var language: String

    let config: DiagramBlocks
    weak var editor: EditorViewing?
    weak var core: EditorCore?
    let getPos: () -> Int?
    private var isSyncing = false

    init(_ node: Node, _ editor: EditorViewing, _ getPos: @escaping () -> Int?, config: DiagramBlocks, core: EditorCore?) {
        self.config = config; self.editor = editor; self.core = core; self.getPos = getPos
        language = DiagramBlocks.language(of: node)
        textView = DiagramTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        super.init()
        (textView as? DiagramTextView)?.owner = self
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = theme.codeBackground
        textView.delegate = self
        setSource(node.textContent)
    }

    var theme: Theme { core?.renderer.theme ?? .standard }

    /// The source shown in the editor.
    public var source: String { textView.string }

    private func setSource(_ source: String) {
        isSyncing = true
        defer { isSyncing = false }
        let selection = textView.selectedRange()
        textView.string = source
        let length = (source as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        restyle()
    }

    /// Highlights and lints the source, and computes the size.
    private func restyle() {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        diagnostics = config.style(storage, language: language, theme: theme, fallback: core?.renderer.highlighter)
        storage.endEditing()
        textView.typingAttributes = [.font: theme.codeFont, .foregroundColor: theme.textColor]
        let hostWidth = (editor as? NSTextView)?.textContainer?.size.width ?? 480
        let width = max(hostWidth - 24, 120)
        textView.textContainer?.containerSize = NSSize(width: width - textView.textContainerInset.width * 2, height: .greatestFiniteMagnitude)
        var height = theme.codeFont.ascender - theme.codeFont.descender
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            height = max(height, layout.usedRect(for: container).height)
        }
        size = CGSize(width: width, height: ceil(height + textView.textContainerInset.height * 2))
        textView.frame.size = size
    }

    public func update(_ node: Node, _ decorations: [Decoration]) -> Bool {
        guard config.isDiagram(node) else { return false }
        let newLanguage = DiagramBlocks.language(of: node)
        if node.textContent != source || newLanguage != language {
            language = newLanguage
            setSource(node.textContent)
        }
        return true
    }

    public func textDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        restyle()
        guard let editor, let pos = getPos(),
              let tr = DiagramBlocks.sourceTransaction(editor.state, pos: pos, source: source) else { return }
        editor.dispatch(tr)
        (editor as? ButtermilkTextView)?.nodeViewSizeChanged(self)
    }

    // MARK: Cursor

    public func focus(atEnd: Bool) {
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: atEnd ? (source as NSString).length : 0, length: 0))
    }

    /// Gives the cursor back to the document, before the block (`dir` -1) or after it.
    public func leave(_ dir: Int) {
        guard let core, let pos = getPos() else { return }
        core.leaveNodeView(at: pos, dir: dir)
        if let host = editor as? NSView { host.window?.makeFirstResponder(host) }
    }

    /// Whether the cursor is on the first (`dir` -1) or last line.
    func onEdgeLine(_ dir: Int) -> Bool {
        let range = textView.selectedRange(), length = (source as NSString).length
        guard range.length == 0 else { return false }
        guard length > 0, let layout = textView.layoutManager else { return true }
        let glyph = layout.glyphIndexForCharacter(at: min(range.location, length - 1))
        var line = NSRange()
        layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let chars = layout.characterRange(forGlyphRange: line, actualGlyphRange: nil)
        if dir < 0 { return chars.location == 0 }
        // After a trailing newline the cursor sits on an empty last line.
        if range.location == length { return true }
        return NSMaxRange(chars) >= length && !(source as NSString).substring(from: chars.location).contains("\n")
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let range = textView.selectedRange(), length = (source as NSString).length
        switch selector {
        case #selector(NSResponder.moveUp(_:)) where onEdgeLine(-1): leave(-1)
        case #selector(NSResponder.moveDown(_:)) where onEdgeLine(1): leave(1)
        case #selector(NSResponder.moveLeft(_:)) where range == NSRange(location: 0, length: 0): leave(-1)
        case #selector(NSResponder.moveRight(_:)) where range == NSRange(location: length, length: 0): leave(1)
        default: return false
        }
        return true
    }

    // MARK: Completion

    /// The completions for the partial word before the cursor, and that word's range.
    public func completions() -> (range: NSRange, words: [String]) {
        config.completions(in: source, at: textView.selectedRange().location, language: language)
    }

    public func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                         indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let found = config.completions(in: source, at: NSMaxRange(charRange), language: language).words
        index?.pointee = found.isEmpty ? -1 : 0
        return found
    }
}

/// The text view of a ``DiagramEditor``.
final class DiagramTextView: NSTextView {
    weak var owner: DiagramEditor?

    override var rangeForUserCompletion: NSRange {
        owner?.completions().range ?? super.rangeForUserCompletion
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
            complete(nil); return
        }
        super.keyDown(with: event)
    }

    /// Passes shortcuts this view does not handle (undo, redo, ...) to the document's keymaps.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let key = ButtermilkTextView.keyPress(event),
              !(key.modifiers == .command && ["c", "x", "v", "a"].contains(key.key.lowercased())),
              let core = owner?.core else { return super.performKeyEquivalent(with: event) }
        if core.handleKey(key) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking in the block selects it in the document, so the selection stays consistent.
        if let owner, let core = owner.core, let pos = owner.getPos(),
           (core.state.selection as? NodeSelection)?.from != pos {
            core.dispatch(core.state.tr.setSelection(NodeSelection.create(core.state.doc, pos)))
        }
        super.mouseDown(with: event)
    }
}
#endif
