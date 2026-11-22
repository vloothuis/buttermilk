import ButtermilkCore
import Foundation

/// The platform-independent part of an editor view: it owns the state, runs plugin views,
/// keymaps and input handlers, and renders the document.
///
/// The AppKit and UIKit text views each own one and act as its ``EditorViewing`` host.
public final class EditorCore {
    public private(set) var state: EditorState
    public private(set) var rendered: RenderedDocument
    public var renderer: DocumentRenderer {
        didSet {
            let old = rendered
            rendered = renderer.render(state.doc, decorations: decorations)
            pendingChange = TextChange(range: NSRange(location: 0, length: old.length), replacement: rendered.text)
            onChange?(state, state)
        }
    }
    /// The text change from the last document update, for the view to apply to its storage.
    var pendingChange: TextChange?
    /// Used by the owning view to redraw after a state change.
    var onChange: ((EditorState, EditorState) -> Void)?
    /// Called after every state change with the new and the previous state.
    public var onChangeObservers: [(EditorState, EditorState) -> Void] = []
    /// Called when the user activates a link. The view opens nothing by itself.
    public var openLink: ((URL) -> Void)?
    /// Called to process a transaction. The default applies it with ``apply(_:)``.
    public var dispatchTransaction: ((Transaction) -> Void)?

    /// Whether the last applied transaction asked to scroll the selection into view.
    public private(set) var scrollRequested = false

    /// The decorations shown: those of the ``EditorProps/decorations`` props of all plugins.
    public private(set) var decorations: DecorationSet = .empty

    weak var host: EditorViewing?
    private var pluginViews: [PluginView] = []

    /// The pasteboard type that carries a slice as JSON, so copy and paste keep structure.
    public static let sliceType = "dev.buttermilk.slice"

    public init(state: EditorState, theme: Theme = .standard) {
        self.state = state
        renderer = DocumentRenderer(theme: theme)
        decorations = Self.decorations(for: state)
        rendered = renderer.render(state.doc, decorations: decorations)
    }

    func attach(_ host: EditorViewing) {
        self.host = host
        makePluginViews()
    }

    deinit { pluginViews.forEach { $0.destroy() } }

    private func makePluginViews() {
        pluginViews.forEach { $0.destroy() }
        guard let host else { pluginViews = []; return }
        pluginViews = state.plugins.compactMap { $0.view?(host) }
    }

    // MARK: State

    public func dispatch(_ tr: Transaction) {
        if let dispatchTransaction { dispatchTransaction(tr) } else { apply(tr) }
    }

    /// Applies a transaction and updates the view.
    public func apply(_ tr: Transaction) {
        guard let next = try? state.apply(tr) else { return }
        scrollRequested = tr.scrolledIntoView
        update(next)
        scrollRequested = false
    }

    /// Replaces the state. Plugin views are recreated when the plugin list changes.
    public func update(_ next: EditorState) {
        let prev = state
        state = next
        let pluginsChanged = prev.plugins.map(\.key) != next.plugins.map(\.key)
        let prevDecorations = decorations
        decorations = Self.decorations(for: next)
        if prev.doc !== next.doc || prevDecorations.all != decorations.all {
            let change = renderer.update(&rendered, to: next.doc, decorations: decorations)
            if change.range.length > 0 || change.replacement.length > 0 { pendingChange = change }
        }
        if pluginsChanged { makePluginViews() }
        if let host { pluginViews.forEach { $0.update(host, prev) } }
        onChange?(next, prev)
        onChangeObservers.forEach { $0(next, prev) }
    }

    static func decorations(for state: EditorState) -> DecorationSet {
        let sets = state.plugins.compactMap { $0.props.decorations?(state) }.filter { !$0.isEmpty }
        if sets.count <= 1 { return sets.first ?? .empty }
        return DecorationSet.create(state.doc, sets.flatMap(\.all))
    }

    public var editable: Bool {
        for plugin in state.plugins { if let f = plugin.props.editable { return f(state) } }
        return true
    }

    func someProp<T>(_ get: (EditorProps) -> T?) -> [T] {
        state.plugins.compactMap { get($0.props) }
    }

    // MARK: Keys

    /// Runs plugin key handlers, then the base keymap. Returns true when the key was handled.
    public func handleKey(_ key: KeyPress) -> Bool {
        guard let host else { return false }
        for handler in someProp({ $0.handleKeyDown }) where handler(host, key) { return true }
        guard editable else { return false }
        return Self.baseHandler(host, key)
    }

    private static let baseHandler = Keymap.handler(Commands.baseKeymap)

    /// Runs a command against the current state.
    @discardableResult
    public func run(_ command: Command) -> Bool {
        command(state, { [weak self] in self?.dispatch($0) }, host)
    }

    // MARK: Text input

    /// Inserts typed text over the document range `from..<to`, giving input handlers (such as
    /// input rules) the first chance.
    public func insertText(_ text: String, from: Int, to: Int) {
        guard let host, editable else { return }
        for handler in someProp({ $0.handleTextInput }) where handler(host, from, to, text) { return }
        guard var tr = try? state.tr.insertText(text, from, to) else { return }
        tr = tr.scrollIntoView()
        dispatch(tr)
    }

    /// Inserts typed text over the selection.
    public func insertText(_ text: String) {
        let sel = state.selection
        if !(sel is TextSelection), !sel.isEmpty {
            // Typing over a node or cell selection replaces it.
            guard let tr = try? state.tr.deleteSelection() else { return }
            dispatch(tr)
        }
        insertText(text, from: state.selection.from, to: state.selection.to)
    }

    /// Deletes the document range, used when the platform asks for a plain character delete.
    public func delete(from: Int, to: Int) {
        guard editable, from < to, let tr = try? state.tr.delete(from, to) else { return }
        dispatch(tr.scrollIntoView())
    }

    public func deleteSelection() {
        guard editable, !state.selection.isEmpty, let tr = try? state.tr.deleteSelection() else { return }
        dispatch(tr.scrollIntoView())
    }

    // MARK: Clipboard

    /// Plain text and slice JSON for the current selection, or nil when it is empty.
    public func copyContent() -> (text: String, json: String)? {
        let sel = state.selection
        guard !sel.isEmpty else { return nil }
        let slice = sel.content()
        let text = slice.content.textBetween(0, slice.content.size, blockSeparator: "\n\n", leafText: { _ in "\n" })
        let json = slice.toJSON()?.serialized() ?? "null"
        return (text, json)
    }

    /// Pastes a slice from JSON, or plain text split into paragraphs.
    public func paste(json: String?, text: String?) {
        guard editable else { return }
        var slice: Slice?
        if let json, let data = json.data(using: .utf8), let value = try? JSON(data: data) {
            slice = try? Slice.fromJSON(state.schema, value)
        }
        if slice == nil, let text { slice = plainTextSlice(text) }
        guard let slice, let host else { return }
        for handler in someProp({ $0.handlePaste }) where handler(host, slice) { return }
        guard let tr = try? state.tr.replaceSelection(slice) else { return }
        dispatch(tr.scrollIntoView())
    }

    func plainTextSlice(_ text: String) -> Slice? {
        let schema = state.schema
        let marks = state.selection.resolvedFrom.marks()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count == 1 {
            guard !text.isEmpty else { return nil }
            return Slice(Fragment.from(schema.text(text, marks: marks)), openStart: 0, openEnd: 0)
        }
        guard let paragraph = schema.nodes["paragraph"] else {
            return Slice(Fragment.from(schema.text(lines.joined(separator: " "), marks: marks)), openStart: 0, openEnd: 0)
        }
        let blocks = lines.compactMap { line -> Node? in
            paragraph.createAndFill(nil, line.isEmpty ? .empty : Fragment.from(schema.text(line, marks: marks)))
        }
        return Slice(Fragment.fromArray(blocks), openStart: 1, openEnd: 1)
    }
}
