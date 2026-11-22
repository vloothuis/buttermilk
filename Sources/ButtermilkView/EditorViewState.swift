import ButtermilkCore
import Foundation

/// The selection and scroll position of an editor view, to save and restore, for example when
/// the app is relaunched or a document is reopened.
///
/// The selection is kept in its JSON form (``Selection/toJSON()``), so node, cell and gap
/// cursor selections survive. The scroll position is kept as a ``ScrollAnchor``: a document
/// position and an offset from its line, so it stays put when the width or theme changes.
public struct EditorViewState: Codable, Hashable, Sendable {
    /// The selection as JSON, or nil to leave the selection alone on restore.
    public var selection: JSON?
    /// The scroll position, or nil to leave the scroll position alone on restore.
    public var scrollAnchor: ScrollAnchor?

    public init(selection: JSON? = nil, scrollAnchor: ScrollAnchor? = nil) {
        self.selection = selection
        self.scrollAnchor = scrollAnchor
    }
}

/// A scroll position relative to the document: the top of the visible area is `offset` points
/// below the top of the line that holds document position `pos`.
public struct ScrollAnchor: Codable, Hashable, Sendable {
    public var pos: Int
    public var offset: Double

    public init(pos: Int, offset: Double) {
        self.pos = pos
        self.offset = offset
    }
}

extension EditorCore {
    /// The selection that `json` describes in the current document. Positions out of range
    /// are clamped; a selection that no longer fits its type becomes a text selection near it.
    public func selection(fromJSON json: JSON) -> Selection {
        let doc = state.doc
        if let selection = try? Selection.fromJSON(doc, json) { return selection }
        let size = doc.content.size
        func pos(_ key: String) -> Int? { json[key]?.intValue.map { min(max($0, 0), size) } }
        let head = pos("head") ?? pos("pos") ?? pos("anchor") ?? 0
        let anchor = pos("anchor") ?? head
        return TextSelection.between(doc.resolve(anchor), doc.resolve(head))
    }

    /// Sets the selection from its JSON form, clamped to the current document.
    public func restoreSelection(_ json: JSON) {
        apply(state.tr.setSelection(selection(fromJSON: json)))
    }

    /// The scroll anchor position clamped to the current document.
    func clampedPosition(_ anchor: ScrollAnchor) -> Int { min(max(anchor.pos, 0), state.doc.content.size) }
}
