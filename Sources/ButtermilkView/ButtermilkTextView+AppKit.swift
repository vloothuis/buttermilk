#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ButtermilkCore

/// A native macOS editor view. It is an `NSTextView`, so it gets system text input, spell
/// checking, dictation and accessibility, while the document lives in an ``EditorState``.
///
/// The text storage is a rendering of the document. Edits never change the storage directly:
/// they become transactions, and the storage is rendered again from the new document.
open class ButtermilkTextView: NSTextView, EditorViewing {
    public let core: EditorCore
    private var isRendering = false
        /// Document range the current composition replaces.
    private var compositionRange: (from: Int, to: Int)?
    private var lastMoveBias = 1
    private var pendingScrollAnchor: ScrollAnchor?
    private var isApplyingScrollAnchor = false

    public var state: EditorState { core.state }
    public var composing: Bool { compositionRange != nil }

    public init(state: EditorState, theme: Theme = .standard, frame: NSRect = NSRect(x: 0, y: 0, width: 480, height: 320)) {
        core = EditorCore(state: state, theme: theme)
        // TextKit 1: NSTextTable needs it.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        super.init(frame: frame, textContainer: container)
        isRichText = true
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        usesFindBar = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 8, height: 8)
        core.attach(self)
        core.onChange = { [weak self] next, prev in self?.stateChanged(next, prev) }
        renderDocument()
        renderSelection()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("Use init(state:theme:frame:)")
    }

    // MARK: EditorViewing

    public func dispatch(_ tr: Transaction) { core.dispatch(tr) }

    public func endOfTextblock(_ dir: TextDirection, _ state: EditorState) -> Bool? {
        guard let layoutManager, state.selection is TextSelection else { return nil }
        let head = state.selection.resolvedHead
        guard head.parent.isTextblock else { return nil }
        let map = core.rendered.map
        let offset = map.offset(for: head.pos)
        let start = map.offset(for: head.start()), end = map.offset(for: head.end())
        switch dir {
        case .left, .backward: return offset == start
        case .right, .forward: return offset == end
        case .up, .down:
            let length = (string as NSString).length
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
        needsDisplay = true
    }

    private func applyChange(_ change: TextChange) {
        guard let storage = textStorage else { return }
        isRendering = true
        defer { isRendering = false }
        storage.beginEditing()
        storage.replaceCharacters(in: change.range, with: change.replacement)
        storage.endEditing()
        syncNodeViews()
    }

    private func renderDocument() {
        guard let storage = textStorage else { return }
        isRendering = true
        defer { isRendering = false }
        storage.beginEditing()
        storage.setAttributedString(core.rendered.text)
        storage.endEditing()
        syncNodeViews()
        typingAttributes = [.font: core.renderer.theme.font, .foregroundColor: core.renderer.theme.textColor]
    }

    private func renderSelection() {
        isRendering = true
        defer { isRendering = false }
        let map = core.rendered.map, sel = state.selection
        let length = (string as NSString).length
        func clamp(_ i: Int) -> Int { min(max(i, 0), length) }
        if let cells = sel as? CellSelection {
            var ranges: [NSValue] = []
            cells.forEachCell { cell, pos in
                let from = clamp(map.offset(for: pos + 1)), to = clamp(map.offset(for: pos + cell.nodeSize - 1, bias: -1))
                ranges.append(NSValue(range: NSRange(location: from, length: max(to - from, 0))))
            }
            if !ranges.isEmpty { super.setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false) }
        } else {
            let from = clamp(map.offset(for: sel.from)), to = clamp(map.offset(for: sel.to, bias: -1))
            var range = NSRange(location: from, length: max(to - from, 0))
            if sel is NodeSelection, to <= from { range.length = min(1, length - from) }
            super.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: false)
        }
        core.nodeViewManager.updateSelection(sel, map)
        if core.scrollRequested { scrollSelectionToVisible() }
    }

    // MARK: Node views

    /// The node views shown, in document order.
    public var nodeViews: [NodeView] { core.nodeViewManager.entries.map(\.nodeView) }

    private func syncNodeViews() {
        guard let storage = textStorage else { return }
        for entry in core.syncNodeViews(storage) {
            layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
            if entry.nodeView.view.superview !== self { addSubview(entry.nodeView.view) }
        }
        layoutNodeViews()
    }

    /// Call when a node view's ``NodeView/size`` changed, to make room for it.
    public func nodeViewSizeChanged(_ nodeView: NodeView) {
        guard let entry = core.nodeViewManager.entries.first(where: { $0.nodeView === nodeView }) else { return }
        entry.attachment.bounds = CGRect(origin: .zero, size: nodeView.size)
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
        layoutNodeViews()
    }

    /// Moves each node view over its attachment character.
    public func layoutNodeViews() {
        let entries = core.nodeViewManager.entries
        guard !entries.isEmpty, let layoutManager else { return }
        let origin = textContainerOrigin
        for entry in entries {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: entry.offset, length: 1), actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            layoutManager.ensureLayout(forGlyphRange: glyphs)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyphs.location)
            let bounds = entry.attachment.bounds
            entry.nodeView.view.frame = CGRect(x: origin.x + line.minX + location.x,
                                               y: origin.y + line.minY + location.y - bounds.maxY,
                                               width: bounds.width, height: bounds.height)
        }
    }

    override open func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutNodeViews()
        applyPendingScrollAnchor()
    }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingScrollAnchor()
    }

    // MARK: View state

    /// The current selection and scroll position.
    public func saveViewState() -> EditorViewState {
        EditorViewState(selection: state.selection.toJSON(), scrollAnchor: pendingScrollAnchor ?? scrollAnchor())
    }

    /// Restores a saved selection and scroll position, clamped to the current document. When
    /// the view is not in a scroll view yet, the scroll position is applied at the next resize
    /// or when the view moves to a window.
    public func restoreViewState(_ viewState: EditorViewState) {
        if let json = viewState.selection { core.restoreSelection(json) }
        if let anchor = viewState.scrollAnchor { pendingScrollAnchor = anchor; applyPendingScrollAnchor() }
    }

    /// The scroll anchor for the top of the visible area, or nil outside a scroll view.
    public func scrollAnchor() -> ScrollAnchor? {
        guard let clip = enclosingScrollView?.contentView, let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return ScrollAnchor(pos: 0, offset: 0) }
        let top = convert(clip.bounds, from: clip).minY - textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(top, 0)), in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let offset = min(layoutManager.characterIndexForGlyph(at: glyph), length - 1)
        return ScrollAnchor(pos: core.rendered.map.position(for: offset), offset: Double(top - line.minY))
    }

    /// Scrolls so the top of the visible area is at `anchor`. Returns false outside a scroll view.
    @discardableResult
    public func scroll(to anchor: ScrollAnchor) -> Bool {
        guard let scrollView = enclosingScrollView, let layoutManager, let textContainer else { return false }
        let length = (string as NSString).length
        var y = -textContainerOrigin.y
        if length > 0 {
            let offset = min(core.rendered.map.offset(for: core.clampedPosition(anchor)), length - 1)
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
            y = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
        }
        // Non-contiguous layout may not have sized the view past the anchor yet.
        let used = layoutManager.usedRect(for: textContainer).maxY + 2 * textContainerOrigin.y
        if frame.height < used { setFrameSize(NSSize(width: frame.width, height: used)) }
        let clip = scrollView.contentView
        var point = convert(NSPoint(x: 0, y: y + textContainerOrigin.y + CGFloat(anchor.offset)), to: clip)
        point.x = clip.bounds.minX
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    private func applyPendingScrollAnchor() {
        guard let anchor = pendingScrollAnchor, !isApplyingScrollAnchor else { return }
        isApplyingScrollAnchor = true
        defer { isApplyingScrollAnchor = false }
        if scroll(to: anchor) { pendingScrollAnchor = nil }
    }

    /// Scrolls to the selection head. Unlike `scrollRangeToVisible`, this only lays out the
    /// text around the selection, which matters for long documents.
    private func scrollSelectionToVisible() {
        guard enclosingScrollView != nil, let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        let offset = min(core.rendered.map.offset(for: state.selection.head), length)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(rect.width, 1)
        scrollToVisible(rect.insetBy(dx: 0, dy: -8))
    }

    // MARK: Selection from TextKit

    override open func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !isRendering, !composing, let range = ranges.first?.rangeValue else { return }
        let map = core.rendered.map, doc = state.doc
        let anchorOffset = selectionAffinity == .upstream ? NSMaxRange(range) : range.location
        var anchor = map.position(for: range.location, bias: lastMoveBias)
        var head = map.position(for: NSMaxRange(range), bias: -1)
        if range.length == 0 { head = anchor }
        anchor = min(max(anchor, 0), doc.content.size); head = min(max(head, 0), doc.content.size)
        _ = anchorOffset
        let current = state.selection
        if current.from == min(anchor, head), current.to == max(anchor, head) { return }
        let resolvedAnchor = doc.resolve(anchor), resolvedHead = doc.resolve(head)
        var selection: Selection?
        if stillSelecting || ranges.count == 1 {
            for f in core.someProp({ $0.createSelectionBetween }) {
                if let s = f(self, resolvedAnchor, resolvedHead) { selection = s; break }
            }
        }
        if selection == nil, let atom = map.atom(at: range.location), range.length <= 1,
           let node = doc.nodeAt(atom.pos), NodeSelection.isSelectable(node) {
            selection = NodeSelection.create(doc, atom.pos)
        }
        let next = selection ?? TextSelection.between(resolvedAnchor, resolvedHead)
        if stillSelecting, Tables.isInTable(state), !(next is TextSelection) || resolvedAnchor.sharedDepth(head) < 3 {
            Tables.dragCellSelection(self, anchor: resolvedAnchor, head: resolvedHead)
            return
        }
        core.dispatch(state.tr.setSelection(next))
    }

    // MARK: Keys

    override open func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let key = Self.keyPress(event), core.handleKey(key) { return }
        super.keyDown(with: event)
    }

    override open func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let key = Self.keyPress(event) else { return super.performKeyEquivalent(with: event) }
        // Let the standard edit menu shortcuts through.
        if key.modifiers == .command, ["c", "x", "v", "a"].contains(key.key.lowercased()) {
            return super.performKeyEquivalent(with: event)
        }
        if core.handleKey(key) { return true }
        return super.performKeyEquivalent(with: event)
    }

    static func keyPress(_ event: NSEvent) -> KeyPress? {
        guard event.type == .keyDown else { return nil }
        var mods: KeyPress.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        let key: String
        switch event.specialKey {
        case .carriageReturn?, .enter?, .newline?: key = "Enter"
        case .backspace?, .delete?: key = "Backspace"
        case .deleteForward?: key = "Delete"
        case .tab?, .backTab?: key = "Tab"
        case .leftArrow?: key = "ArrowLeft"
        case .rightArrow?: key = "ArrowRight"
        case .upArrow?: key = "ArrowUp"
        case .downArrow?: key = "ArrowDown"
        case .home?: key = "Home"
        case .end?: key = "End"
        case .pageUp?: key = "PageUp"
        case .pageDown?: key = "PageDown"
        case .some: return nil
        case nil:
            if event.keyCode == 53 { key = "Escape"; break }
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            // With shift, keep the shifted character but drop shift for letters, like the DOM.
            key = chars
        }
        let base = event.characters(byApplyingModifiers: [])
        return KeyPress(key, modifiers: mods, baseKey: base)
    }

    // MARK: Text input

    override open func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        isRendering || hasMarkedText() || composing
    }

    override open func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if isUnmarking { return }
        if let comp = compositionRange {
            // End of composition: drop the marked text from the storage, then insert through the state.
            endMarkedText()
            if !text.isEmpty { core.insertText(text, from: comp.from, to: comp.to) } else { renderSelection() }
            return
        }
        guard !text.isEmpty else { return }
        if replacementRange.location != NSNotFound, replacementRange.length > 0 {
            let map = core.rendered.map
            let from = map.position(for: replacementRange.location), to = map.position(for: NSMaxRange(replacementRange), bias: -1)
            core.insertText(text, from: from, to: max(from, to))
        } else {
            core.insertText(text)
        }
    }

    override open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if compositionRange == nil {
            let sel = state.selection
            compositionRange = (sel.from, sel.to)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if text.isEmpty { unmarkText() }
    }

    override open func unmarkText() {
        guard let comp = compositionRange else { super.unmarkText(); return }
        let marked = markedRange()
        let text = marked.location == NSNotFound ? "" : (string as NSString).substring(with: marked)
        endMarkedText()
        if !text.isEmpty { core.insertText(text, from: comp.from, to: comp.to) } else { renderSelection() }
    }

    /// NSTextView commits marked text through `insertText`; ignore that, the state does it.
    private var isUnmarking = false

    private func endMarkedText() {
        compositionRange = nil
        isUnmarking = true
        // An empty marked string removes the marked text, so the storage matches the rendering
        // again, and ends the composition without NSTextView committing it.
        super.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        isUnmarking = false
    }

    override open func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            _ = core.handleKey(KeyPress("Enter"))
        case #selector(insertLineBreak(_:)):
            _ = core.handleKey(KeyPress("Enter", modifiers: .shift))
        case #selector(insertTab(_:)):
            if !core.handleKey(KeyPress("Tab")) { core.insertText("\t") }
        case #selector(insertBacktab(_:)):
            _ = core.handleKey(KeyPress("Tab", modifiers: .shift))
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)):
            if !core.handleKey(KeyPress("Backspace")) { deleteCharacter(forward: false) }
        case #selector(deleteForward(_:)):
            if !core.handleKey(KeyPress("Delete")) { deleteCharacter(forward: true) }
        case #selector(deleteWordBackward(_:)): deleteExtending(#selector(moveWordBackwardAndModifySelection(_:)))
        case #selector(deleteWordForward(_:)): deleteExtending(#selector(moveWordForwardAndModifySelection(_:)))
        case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)):
            deleteExtending(#selector(moveToBeginningOfLineAndModifySelection(_:)))
        case #selector(deleteToEndOfLine(_:)), #selector(deleteToEndOfParagraph(_:)):
            deleteExtending(#selector(moveToEndOfLineAndModifySelection(_:)))
        case #selector(cancelOperation(_:)):
            _ = core.handleKey(KeyPress("Escape"))
        default:
            let name = NSStringFromSelector(selector)
            lastMoveBias = name.contains("Backward") || name.contains("Left") || name.contains("Up") || name.contains("Beginning") ? -1 : 1
            super.doCommand(by: selector)
            lastMoveBias = 1
        }
    }

    private func deleteCharacter(forward: Bool) {
        let sel = state.selection
        if !sel.isEmpty { core.deleteSelection(); return }
        let pos = sel.from, text = string as NSString
        let offset = core.rendered.map.offset(for: pos)
        guard core.rendered.map.isInText(offset) else { return }
        let range: NSRange
        if forward {
            guard offset < text.length else { return }
            range = text.rangeOfComposedCharacterSequence(at: offset)
        } else {
            guard offset > 0 else { return }
            range = text.rangeOfComposedCharacterSequence(at: offset - 1)
        }
        let map = core.rendered.map
        let from = map.position(for: range.location, bias: -1), to = map.position(for: NSMaxRange(range))
        core.delete(from: min(from, to), to: max(from, to))
    }

    private func deleteExtending(_ move: Selector) {
        if state.selection.isEmpty {
            lastMoveBias = NSStringFromSelector(move).contains("Backward") || NSStringFromSelector(move).contains("Beginning") ? -1 : 1
            super.doCommand(by: move)
            lastMoveBias = 1
        }
        core.deleteSelection()
    }

    // MARK: Mouse

    override open func mouseDown(with event: NSEvent) {
        if event.clickCount == 3 {
            let point = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: point)
            let pos = core.rendered.map.position(for: offset)
            for handler in core.someProp({ $0.handleTripleClick }) where handler(self, pos) { return }
        }
        super.mouseDown(with: event)
        Tables.endCellDrag(self)
    }

    /// Adds the table controls to the context menu when the selection is in a table.
    override open func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let controls = core.tableControls
        guard !controls.isEmpty else { return menu }
        var index = 0
        for control in controls {
            let item = NSMenuItem(title: control.title, action: #selector(performTableControl(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = control.rawValue
            menu.insertItem(item, at: index)
            index += 1
            if control == .addColumnAfter || control == .deleteColumn { menu.insertItem(.separator(), at: index); index += 1 }
        }
        if menu.items.count > index, !(menu.items[index - 1].isSeparatorItem) { menu.insertItem(.separator(), at: index) }
        return menu
    }

    @objc private func performTableControl(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let control = TableControl(rawValue: raw) else { return }
        core.run(control)
    }

    override open func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL { core.openLink?(url) }
    }

    // MARK: Clipboard

    override open func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let content = core.copyContent() else { return false }
        let sliceType = NSPasteboard.PasteboardType(EditorCore.sliceType)
        pboard.declareTypes([sliceType, .string], owner: nil)
        pboard.setString(content.json, forType: sliceType)
        pboard.setString(content.text, forType: .string)
        return true
    }

    override open var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(EditorCore.sliceType), .string]
    }

    override open var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NSPasteboard.PasteboardType(EditorCore.sliceType), .string]
    }

    override open func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        paste(from: pboard)
        return true
    }

    override open func paste(_ sender: Any?) { paste(from: .general) }
    override open func pasteAsPlainText(_ sender: Any?) { core.paste(json: nil, text: NSPasteboard.general.string(forType: .string)) }

    override open func cut(_ sender: Any?) {
        copy(sender)
        core.deleteSelection()
    }

    private func paste(from pboard: NSPasteboard) {
        core.paste(json: pboard.string(forType: NSPasteboard.PasteboardType(EditorCore.sliceType)),
                   text: pboard.string(forType: .string))
    }

    override open func selectAll(_ sender: Any?) {
        core.dispatch(state.tr.setSelection(AllSelection(state.doc)))
    }

    // MARK: Drawing

    override open func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if state.selection is GapCursor {
            guard flag else { return }
            color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 20, height: 1).fill()
            return
        }
        if state.selection is CellSelection || state.selection is NodeSelection { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }
}
#endif
