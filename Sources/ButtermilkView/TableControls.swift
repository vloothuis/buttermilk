import ButtermilkCore

/// A table editing action that a view offers in its context or edit menu.
public enum TableControl: String, CaseIterable, Sendable {
    case addRowBefore, addRowAfter, addColumnBefore, addColumnAfter, deleteRow, deleteColumn, deleteTable

    /// The menu title.
    public var title: String {
        switch self {
        case .addRowBefore: "Insert Row Above"
        case .addRowAfter: "Insert Row Below"
        case .addColumnBefore: "Insert Column Left"
        case .addColumnAfter: "Insert Column Right"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        case .deleteTable: "Delete Table"
        }
    }

    /// The command that performs the action.
    public var command: Command {
        switch self {
        case .addRowBefore: TableCommands.addRowBefore
        case .addRowAfter: TableCommands.addRowAfter
        case .addColumnBefore: TableCommands.addColumnBefore
        case .addColumnAfter: TableCommands.addColumnAfter
        case .deleteRow: TableCommands.deleteRow
        case .deleteColumn: TableCommands.deleteColumn
        case .deleteTable: TableCommands.deleteTable
        }
    }

    /// The controls that apply to `state`, in menu order. Empty outside a table.
    public static func available(in state: EditorState) -> [TableControl] {
        guard Tables.isInTable(state) else { return [] }
        return allCases.filter { $0.command(state, nil, nil) }
    }
}

extension EditorCore {
    /// The table controls that apply to the current selection.
    public var tableControls: [TableControl] { editable ? TableControl.available(in: state) : [] }

    /// Runs a table control. Returns false when it does not apply.
    @discardableResult
    public func run(_ control: TableControl) -> Bool {
        guard editable else { return false }
        return run(control.command)
    }
}
