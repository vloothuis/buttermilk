import Foundation

/// An undo manager that reflects the editor's history, so the system Edit menu, the shake
/// gesture and the undo key commands undo document changes and show their names.
/// Registrations from the text system are ignored: the history plugin owns undo.
public final class EditorUndoManager: UndoManager {
    weak var core: EditorCore?

    init(core: EditorCore) {
        self.core = core
        super.init()
        groupsByEvent = false
    }

    override public var canUndo: Bool { core?.canUndo ?? false }
    override public var canRedo: Bool { core?.canRedo ?? false }
    override public func undo() { core?.undo() }
    override public func redo() { core?.redo() }
    override public var undoActionName: String { core?.undoActionName ?? "" }
    override public var redoActionName: String { core?.redoActionName ?? "" }
    override public var undoMenuItemTitle: String { core?.undoMenuTitle ?? "Undo" }
    override public var redoMenuItemTitle: String { core?.redoMenuTitle ?? "Redo" }

    override public func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {}
    override public func beginUndoGrouping() {}
    override public func endUndoGrouping() {}
    override public func setActionName(_ actionName: String) {}
}
