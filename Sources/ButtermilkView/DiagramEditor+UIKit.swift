#if canImport(UIKit) && !os(watchOS)
import ButtermilkCore
import UIKit

/// The embedded code editor of a diagram block (see ``DiagramBlocks``). It is a node view that
/// hosts its own text view. Each edit becomes a transaction that replaces the block's content.
/// Hardware arrow keys at its first or last line move the cursor back to the document. UIKit has
/// no completion menu; hosts can show ``completions()`` and insert one with ``complete(_:)``.
public final class DiagramEditor: NSObject, EditableNodeView, UITextViewDelegate {
    public let textView: UITextView
    public var view: UIView { textView }
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
        let textView = DiagramTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 20))
        self.textView = textView
        super.init()
        textView.owner = self
        textView.isScrollEnabled = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        textView.backgroundColor = theme.codeBackground
        textView.delegate = self
        setSource(node.textContent)
    }

    var theme: Theme { core?.renderer.theme ?? .standard }

    /// The source shown in the editor.
    public var source: String { textView.text ?? "" }

    private func setSource(_ source: String) {
        isSyncing = true
        defer { isSyncing = false }
        let selection = textView.selectedRange
        textView.text = source
        restyle()
        textView.selectedRange = NSRange(location: min(selection.location, (source as NSString).length), length: 0)
    }

    private func restyle() {
        let selection = textView.selectedRange
        let text = NSMutableAttributedString(string: source)
        diagnostics = config.style(text, language: language, theme: theme, fallback: core?.renderer.highlighter)
        textView.attributedText = text
        textView.selectedRange = selection
        textView.typingAttributes = [.font: theme.codeFont, .foregroundColor: theme.textColor]
        let hostWidth = (editor as? UIView)?.bounds.width ?? 480
        let width = max(hostWidth - 40, 120)
        let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        size = CGSize(width: width, height: ceil(fit.height))
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

    public func textViewDidChange(_ textView: UITextView) {
        guard !isSyncing, textView.markedTextRange == nil else { return }
        restyle()
        guard let editor, let pos = getPos(),
              let tr = DiagramBlocks.sourceTransaction(editor.state, pos: pos, source: source) else { return }
        editor.dispatch(tr)
        (editor as? ButtermilkTextView)?.nodeViewSizeChanged(self)
    }

    public func focus(atEnd: Bool) {
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: atEnd ? (source as NSString).length : 0, length: 0)
    }

    /// Gives the cursor back to the document, before the block (`dir` -1) or after it.
    public func leave(_ dir: Int) {
        guard let core, let pos = getPos() else { return }
        core.leaveNodeView(at: pos, dir: dir)
        (editor as? UIView)?.becomeFirstResponder()
    }

    /// The completions for the partial word before the cursor, and that word's range.
    public func completions() -> (range: NSRange, words: [String]) {
        config.completions(in: source, at: textView.selectedRange.location, language: language)
    }

    /// Replaces the partial word before the cursor with `word`.
    public func complete(_ word: String) {
        let range = completions().range
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: word)
    }

    func arrow(_ dir: Int, vertical: Bool) -> Bool {
        let range = textView.selectedRange, s = source as NSString
        guard range.length == 0 else { return false }
        if !vertical { return dir < 0 ? range.location == 0 : range.location == s.length }
        let before = s.substring(to: range.location), after = s.substring(from: range.location)
        return dir < 0 ? !before.contains("\n") : !after.contains("\n")
    }
}

/// The text view of a ``DiagramEditor``.
final class DiagramTextView: UITextView {
    weak var owner: DiagramEditor?

    override var keyCommands: [UIKeyCommand]? {
        let inputs: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(up)), (UIKeyCommand.inputDownArrow, #selector(down)),
            (UIKeyCommand.inputLeftArrow, #selector(left)), (UIKeyCommand.inputRightArrow, #selector(right)),
        ]
        return inputs.map { input, action in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard let owner else { return super.canPerformAction(action, withSender: sender) }
        switch action {
        case #selector(up): return owner.arrow(-1, vertical: true)
        case #selector(down): return owner.arrow(1, vertical: true)
        case #selector(left): return owner.arrow(-1, vertical: false)
        case #selector(right): return owner.arrow(1, vertical: false)
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc func up() { owner?.leave(-1) }
    @objc func down() { owner?.leave(1) }
    @objc func left() { owner?.leave(-1) }
    @objc func right() { owner?.leave(1) }
}
#endif
