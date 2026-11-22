import Foundation

/// A view that hosts an editor state. Commands and plugin props receive it. The native
/// TextKit view implements it; tests can use a plain object.
public protocol EditorViewing: AnyObject {
    var state: EditorState { get }
    func dispatch(_ tr: Transaction)
}

/// A command. It returns false when it does not apply. When `dispatch` is given and the command
/// applies, it calls `dispatch` with a transaction.
public typealias Command = (_ state: EditorState, _ dispatch: ((Transaction) -> Void)?, _ view: EditorViewing?) -> Bool

/// Something usable as a transaction metadata key: a string, a plugin, or a plugin key.
public protocol MetaKey { var metaKey: String { get } }
extension String: MetaKey { public var metaKey: String { self } }

/// A transform that also tracks the selection, stored marks, and metadata.
public final class Transaction: Transform {
    private struct Updated: OptionSet {
        let rawValue: Int
        static let selection = Updated(rawValue: 1), marks = Updated(rawValue: 2), scroll = Updated(rawValue: 4)
    }

    /// Milliseconds since 1970, like `Date.now()` in JS.
    public var time: Double
    private var curSelection: Selection
    private var curSelectionFor = 0
    private var updated: Updated = []
    private var meta: [String: Any] = [:]
    public private(set) var storedMarks: [Mark]?

    public init(_ state: EditorState) {
        time = (Date().timeIntervalSince1970 * 1000).rounded()
        curSelection = state.selection
        storedMarks = state.storedMarks
        super.init(state.doc)
    }

    /// The selection, mapped through the steps added so far.
    public var selection: Selection {
        if curSelectionFor < steps.count {
            curSelection = curSelection.map(doc, mapping.slice(curSelectionFor))
            curSelectionFor = steps.count
        }
        return curSelection
    }

    /// Set the selection. It must point into the current document.
    @discardableResult
    public func setSelection(_ selection: Selection) -> Self {
        precondition(selection.resolvedFrom.doc === doc, "Selection passed to setSelection must point at the current document")
        curSelection = selection
        curSelectionFor = steps.count
        updated.insert(.selection)
        updated.remove(.marks)
        storedMarks = nil
        return self
    }

    public var selectionSet: Bool { updated.contains(.selection) }

    @discardableResult
    public func setStoredMarks(_ marks: [Mark]?) -> Self {
        storedMarks = marks
        updated.insert(.marks)
        return self
    }

    /// Make sure the stored marks, or the marks at the selection, match `marks`.
    @discardableResult
    public func ensureMarks(_ marks: [Mark]) -> Self {
        if !Mark.sameSet(storedMarks ?? selection.resolvedFrom.marks(), marks) { setStoredMarks(marks) }
        return self
    }

    @discardableResult
    public func addStoredMark(_ mark: Mark) -> Self {
        ensureMarks(mark.addToSet(storedMarks ?? selection.resolvedHead.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ mark: Mark) -> Self {
        ensureMarks(mark.removeFromSet(storedMarks ?? selection.resolvedHead.marks()))
    }

    @discardableResult
    public func removeStoredMark(_ type: MarkType) -> Self {
        ensureMarks(type.removeFromSet(storedMarks ?? selection.resolvedHead.marks()))
    }

    public var storedMarksSet: Bool { updated.contains(.marks) }

    public override func addStep(_ step: Step, _ doc: Node) {
        super.addStep(step, doc)
        updated.remove(.marks)
        storedMarks = nil
    }

    @discardableResult
    public func setTime(_ time: Double) -> Self { self.time = time; return self }

    @discardableResult
    public func replaceSelection(_ slice: Slice) throws -> Self {
        try selection.replace(self, slice)
        return self
    }

    /// Replace the selection with a node. With `inheritMarks`, the node gets the marks at the selection.
    @discardableResult
    public func replaceSelectionWith(_ node: Node, inheritMarks: Bool = true) throws -> Self {
        let sel = selection
        var node = node
        if inheritMarks {
            node = node.mark(storedMarks ?? (sel.isEmpty ? sel.resolvedFrom.marks()
                                             : (sel.resolvedFrom.marksAcross(sel.resolvedTo) ?? Mark.none)))
        }
        try sel.replaceWith(self, node)
        return self
    }

    @discardableResult
    public func deleteSelection() throws -> Self {
        try selection.replace(self)
        return self
    }

    /// Insert text at the selection, or replace the range `from..<to` with it.
    @discardableResult
    public func insertText(_ text: String, _ from: Int? = nil, _ to: Int? = nil) throws -> Self {
        let schema = doc.type.schema
        guard let from else {
            if text.isEmpty { return try deleteSelection() }
            return try replaceSelectionWith(schema.text(text), inheritMarks: true)
        }
        let to = to ?? from
        if text.isEmpty { return try deleteRange(from, to) }
        var marks = storedMarks
        if marks == nil {
            let rFrom = doc.resolve(from)
            marks = to == from ? rFrom.marks() : rFrom.marksAcross(doc.resolve(to))
        }
        try replaceRangeWith(from, to, schema.text(text, marks: marks ?? []))
        if !selection.isEmpty && selection.to == from + text.utf16.count {
            setSelection(Selection.near(selection.resolvedTo))
        }
        return self
    }

    @discardableResult
    public func setMeta(_ key: MetaKey, _ value: Any?) -> Self {
        meta[key.metaKey] = value
        return self
    }

    public func getMeta(_ key: MetaKey) -> Any? { meta[key.metaKey] }

    public func getMeta<T>(_ key: MetaKey, as: T.Type) -> T? { meta[key.metaKey] as? T }

    /// True when the transaction has no metadata.
    public var isGeneric: Bool { meta.isEmpty }

    @discardableResult
    public func scrollIntoView() -> Self { updated.insert(.scroll); return self }

    public var scrolledIntoView: Bool { updated.contains(.scroll) }
}
