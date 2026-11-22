#if canImport(UIKit) && !os(watchOS)
import ButtermilkCore
import UIKit

/// A native iOS editor view. It is a `UITextView`, so it gets the system keyboard, autocorrect,
/// dictation, selection handles and accessibility, while the document lives in an ``EditorState``.
///
/// Edits never change the text storage directly: they become transactions, and the storage is
/// rendered again from the new document.
open class ButtermilkTextView: UITextView, EditorViewing, UITextViewDelegate {
    public let core: EditorCore
    private var isRendering = false
    private var compositionRange: (from: Int, to: Int)?
    private var pendingScrollAnchor: ScrollAnchor?
    private var isApplyingScrollAnchor = false

    public var state: EditorState { core.state }
    public var composing: Bool { compositionRange != nil }

    /// Receives the delegate calls the view does not use itself.
    public weak var forwardingDelegate: UITextViewDelegate?

    public init(state: EditorState, theme: Theme = .standard, frame: CGRect = .zero) {
        core = EditorCore(state: state, theme: theme)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        super.init(frame: frame, textContainer: container)
        delegate = self
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocorrectionType = .default
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        core.attach(self)
        core.onChange = { [weak self] next, prev in self?.stateChanged(next, prev) }
        renderDocument()
        renderSelection()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: EditorViewing

    public func dispatch(_ tr: Transaction) { core.dispatch(tr) }

    public func endOfTextblock(_ dir: TextDirection, _ state: EditorState) -> Bool? {
        guard state.selection is TextSelection else { return nil }
        let head = state.selection.resolvedHead
        guard head.parent.isTextblock else { return nil }
        let map = core.rendered.map
        let offset = map.offset(for: head.pos)
        let start = map.offset(for: head.start()), end = map.offset(for: head.end())
        switch dir {
        case .left, .backward: return offset == start
        case .right, .forward: return offset == end
        case .up, .down:
            let length = (text as NSString).length
            guard length > 0 else { return true }
            let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, length - 1))
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            let chars = layoutManager.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            return dir == .up ? chars.location <= start : NSMaxRange(chars) >= end
        }
    }

    // MARK: Rendering

    private func stateChanged(_ next: EditorState, _ prev: EditorState) {
        if let change = core.pendingChange {
            core.pendingChange = nil
            applyChange(change)
        }
        renderSelection()
    }

    private func applyChange(_ change: TextChange) {
        isRendering = true
        defer { isRendering = false }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: change.range, with: change.replacement)
        textStorage.endEditing()
        syncNodeViews()
    }

    private func renderDocument() {
        isRendering = true
        defer { isRendering = false }
        textStorage.beginEditing()
        textStorage.setAttributedString(core.rendered.text)
        textStorage.endEditing()
        syncNodeViews()
        typingAttributes = [.font: core.renderer.theme.font, .foregroundColor: core.renderer.theme.textColor]
    }

    private func renderSelection() {
        isRendering = true
        defer { isRendering = false }
        let map = core.rendered.map, sel = state.selection
        let length = (text as NSString).length
        func clamp(_ i: Int) -> Int { min(max(i, 0), length) }
        let from = clamp(map.offset(for: sel.from)), to = clamp(map.offset(for: sel.to, bias: -1))
        var range = NSRange(location: from, length: max(to - from, 0))
        if sel is NodeSelection, to <= from { range.length = min(1, length - from) }
        selectedRange = range
        core.nodeViewManager.updateSelection(sel, map)
        if core.scrollRequested {
            // Only lay out around the selection, not the text before it.
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerInset.left
            rect.origin.y += textContainerInset.top
            rect.size.width = max(rect.width, 1)
            scrollRectToVisible(rect.insetBy(dx: 0, dy: -8), animated: false)
        }
    }

    // MARK: Node views

    /// The node views shown, in document order.
    public var nodeViews: [NodeView] { core.nodeViewManager.entries.map(\.nodeView) }

    private func syncNodeViews() {
        for entry in core.syncNodeViews(textStorage) {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
            if entry.nodeView.view.superview !== self { addSubview(entry.nodeView.view) }
        }
        layoutNodeViews()
    }

    /// Call when a node view's ``NodeView/size`` changed, to make room for it.
    public func nodeViewSizeChanged(_ nodeView: NodeView) {
        guard let entry = core.nodeViewManager.entries.first(where: { $0.nodeView === nodeView }) else { return }
        entry.attachment.bounds = CGRect(origin: .zero, size: nodeView.size)
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
        layoutNodeViews()
    }

    /// Moves each node view over its attachment character.
    public func layoutNodeViews() {
        let entries = core.nodeViewManager.entries
        guard !entries.isEmpty else { return }
        for entry in entries {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            layoutManager.ensureLayout(forGlyphRange: glyphs)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyphs.location)
            let bounds = entry.attachment.bounds
            entry.nodeView.view.frame = CGRect(x: textContainerInset.left + line.minX + location.x,
                                               y: textContainerInset.top + line.minY + location.y - bounds.maxY,
                                               width: bounds.width, height: bounds.height)
        }
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        layoutNodeViews()
        applyPendingScrollAnchor()
    }

    // MARK: View state

    /// The current selection and scroll position.
    public func saveViewState() -> EditorViewState {
        EditorViewState(selection: state.selection.toJSON(), scrollAnchor: pendingScrollAnchor ?? scrollAnchor())
    }

    /// Restores a saved selection and scroll position, clamped to the current document. Before
    /// the view has a size, the scroll position is applied at the next layout.
    public func restoreViewState(_ viewState: EditorViewState) {
        if let json = viewState.selection { core.restoreSelection(json) }
        if let anchor = viewState.scrollAnchor { pendingScrollAnchor = anchor; applyPendingScrollAnchor() }
    }

    /// The scroll anchor for the top of the visible area.
    public func scrollAnchor() -> ScrollAnchor {
        let length = (text as NSString).length
        guard length > 0 else { return ScrollAnchor(pos: 0, offset: 0) }
        let top = contentOffset.y + adjustedContentInset.top - textContainerInset.top
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: max(top, 0)), in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let offset = min(layoutManager.characterIndexForGlyph(at: glyph), length - 1)
        return ScrollAnchor(pos: core.rendered.map.position(for: offset), offset: Double(top - line.minY))
    }

    /// Scrolls so the top of the visible area is at `anchor`. Returns false before the view has a size.
    @discardableResult
    public func scroll(to anchor: ScrollAnchor) -> Bool {
        guard bounds.height > 0 else { return false }
        let length = (text as NSString).length
        var y: CGFloat = 0
        if length > 0 {
            let offset = min(core.rendered.map.offset(for: core.clampedPosition(anchor)), length - 1)
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
            y = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        }
        let inset = adjustedContentInset
        let target = y + textContainerInset.top + CGFloat(anchor.offset) - inset.top
        let maxY = max(contentSize.height + inset.bottom - bounds.height, -inset.top)
        contentOffset = CGPoint(x: contentOffset.x, y: min(max(target, -inset.top), maxY))
        return true
    }

    private func applyPendingScrollAnchor() {
        guard let anchor = pendingScrollAnchor, !isApplyingScrollAnchor else { return }
        isApplyingScrollAnchor = true
        defer { isApplyingScrollAnchor = false }
        if scroll(to: anchor) { pendingScrollAnchor = nil }
    }

    // MARK: Delegate

    public func textViewDidChangeSelection(_ textView: UITextView) {
        defer { forwardingDelegate?.textViewDidChangeSelection?(textView) }
        guard !isRendering, !composing, markedTextRange == nil else { return }
        let map = core.rendered.map, doc = state.doc, range = selectedRange
        var anchor = map.position(for: range.location)
        var head = range.length == 0 ? anchor : map.position(for: NSMaxRange(range), bias: -1)
        anchor = min(max(anchor, 0), doc.content.size); head = min(max(head, anchor), doc.content.size)
        if state.selection.from == anchor, state.selection.to == head { return }
        let resolvedAnchor = doc.resolve(anchor), resolvedHead = doc.resolve(head)
        var selection: Selection?
        for f in core.someProp({ $0.createSelectionBetween }) {
            if let s = f(self, resolvedAnchor, resolvedHead) { selection = s; break }
        }
        if selection == nil, range.length <= 1, let atom = map.atom(at: range.location),
           let node = doc.nodeAt(atom.pos), NodeSelection.isSelectable(node) {
            selection = NodeSelection.create(doc, atom.pos)
        }
        core.dispatch(state.tr.setSelection(selection ?? TextSelection.between(resolvedAnchor, resolvedHead)))
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if isRendering || markedTextRange != nil { return true }
        let map = core.rendered.map
        let from = map.position(for: range.location)
        let to = range.length == 0 ? from : max(from, map.position(for: NSMaxRange(range), bias: -1))
        if text == "\n" {
            syncSelection(from, to)
            _ = core.handleKey(KeyPress("Enter"))
        } else if text.isEmpty {
            let sel = state.selection
            if range.length > 0, sel.from == from, sel.to == to {
                if !core.handleKey(KeyPress("Backspace")) { core.deleteSelection() }
            } else if range.length > 0 {
                syncSelection(to, to)
                if !core.handleKey(KeyPress("Backspace")) { core.delete(from: from, to: to) }
            }
        } else {
            core.insertText(text, from: from, to: to)
        }
        return false
    }

    /// Adds a Table submenu with the table controls when the selection is in a table.
    @available(iOS 16.0, *)
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                         suggestedActions: [UIMenuElement]) -> UIMenu? {
        let base = forwardingDelegate?.textView?(textView, editMenuForTextIn: range, suggestedActions: suggestedActions)
            ?? UIMenu(children: suggestedActions)
        let controls = core.tableControls
        guard !controls.isEmpty else { return base }
        let actions = controls.map { control in
            UIAction(title: control.title, attributes: control == .deleteTable ? .destructive : []) { [weak self] _ in
                self?.core.run(control)
            }
        }
        return base.replacingChildren(base.children + [UIMenu(title: "Table", children: actions)])
    }

    public func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                         interaction: UITextItemInteraction) -> Bool {
        core.openLink?(URL)
        return false
    }

    private func syncSelection(_ from: Int, _ to: Int) {
        let sel = state.selection
        guard sel.from != from || sel.to != to else { return }
        let doc = state.doc
        core.dispatch(state.tr.setSelection(TextSelection.between(doc.resolve(from), doc.resolve(to))))
    }

    // MARK: Composition

    override open func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if compositionRange == nil { compositionRange = (state.selection.from, state.selection.to) }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override open func unmarkText() {
        guard let comp = compositionRange else { super.unmarkText(); return }
        let marked = markedTextRange.map { text(in: $0) ?? "" } ?? ""
        let markedRange = markedTextRange.map { NSRange(location: offset(from: beginningOfDocument, to: $0.start),
                                                         length: offset(from: $0.start, to: $0.end)) }
        isRendering = true
        super.unmarkText()
        // UITextView keeps the committed text; drop it so the storage matches the rendering.
        if let markedRange { textStorage.replaceCharacters(in: markedRange, with: "") }
        isRendering = false
        compositionRange = nil
        if !marked.isEmpty { core.insertText(marked, from: comp.from, to: comp.to) } else { renderSelection() }
    }

    // MARK: Hardware keys

    override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, let keyPress = Self.keyPress(key), markedTextRange == nil else { continue }
            // Plain characters go through text input so autocorrect and input rules see them.
            if keyPress.modifiers.isSubset(of: .shift), keyPress.key.count == 1 { continue }
            if core.handleKey(keyPress) { return }
        }
        super.pressesBegan(presses, with: event)
    }

    static func keyPress(_ key: UIKey) -> KeyPress? {
        var mods: KeyPress.Modifiers = []
        if key.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if key.modifierFlags.contains(.control) { mods.insert(.control) }
        if key.modifierFlags.contains(.alternate) { mods.insert(.option) }
        if key.modifierFlags.contains(.command) { mods.insert(.command) }
        let name: String
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: name = "Enter"
        case .keyboardDeleteOrBackspace: name = "Backspace"
        case .keyboardDeleteForward: name = "Delete"
        case .keyboardTab: name = "Tab"
        case .keyboardLeftArrow: name = "ArrowLeft"
        case .keyboardRightArrow: name = "ArrowRight"
        case .keyboardUpArrow: name = "ArrowUp"
        case .keyboardDownArrow: name = "ArrowDown"
        case .keyboardEscape: name = "Escape"
        case .keyboardHome: name = "Home"
        case .keyboardEnd: name = "End"
        default:
            guard !key.charactersIgnoringModifiers.isEmpty else { return nil }
            name = key.charactersIgnoringModifiers
        }
        // Arrow keys and editing keys without modifiers are left to UITextView unless a keymap wants them.
        return KeyPress(name, modifiers: mods, baseKey: key.charactersIgnoringModifiers)
    }

    // MARK: Clipboard

    override open func copy(_ sender: Any?) {
        guard let content = core.copyContent() else { return }
        UIPasteboard.general.items = [[EditorCore.sliceType: content.json, "public.utf8-plain-text": content.text]]
    }

    override open func cut(_ sender: Any?) {
        copy(sender)
        core.deleteSelection(actionName: "Cut")
    }

    override open func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        let json = pb.data(forPasteboardType: EditorCore.sliceType).flatMap { String(data: $0, encoding: .utf8) }
            ?? pb.value(forPasteboardType: EditorCore.sliceType) as? String
        core.paste(json: json, text: pb.string)
    }

    // MARK: Undo

    private lazy var editorUndoManager = EditorUndoManager(core: core)

    /// Undo follows the editor history, so the edit menu shows titles such as "Undo Typing".
    override open var undoManager: UndoManager? { editorUndoManager }

    override open func selectAll(_ sender: Any?) {
        core.dispatch(state.tr.setSelection(AllSelection(state.doc)))
    }
}
#endif
