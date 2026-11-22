import Foundation

/// A key press, as passed to `handleKeyDown`. `key` follows the DOM `KeyboardEvent.key` naming
/// ("a", "Enter", "ArrowLeft", "Backspace").
public struct KeyPress: Equatable {
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }
    public var key: String
    public var modifiers: Modifiers
    /// The key as it would be on a US layout, if known (for example from the hardware key code).
    /// Keymaps fall back to it so that shortcuts keep working on non-Latin layouts.
    public var baseKey: String?
    public init(_ key: String, modifiers: Modifiers = [], baseKey: String? = nil) {
        self.key = key; self.modifiers = modifiers; self.baseKey = baseKey
    }
}

/// Props that plugins can provide to the view. The view asks each plugin in order and stops
/// at the first handler that returns true.
public struct EditorProps {
    public var handleKeyDown: ((EditorViewing, KeyPress) -> Bool)?
    public var handleTextInput: ((EditorViewing, _ from: Int, _ to: Int, _ text: String) -> Bool)?
    public var handlePaste: ((EditorViewing, Slice) -> Bool)?
    public var editable: ((EditorState) -> Bool)?
    /// Called on a triple click at document position `pos`.
    public var handleTripleClick: ((EditorViewing, _ pos: Int) -> Bool)?
    /// Lets a plugin override the selection a mouse drag creates. Return nil for the default.
    public var createSelectionBetween: ((EditorViewing, _ anchor: ResolvedPos, _ head: ResolvedPos) -> Selection?)?
    /// Decorations to show for a state. The view combines the sets of all plugins.
    public var decorations: ((EditorState) -> DecorationSet)?
    public init() {}
}

/// An object a plugin keeps alongside a view. It is told about state updates.
public protocol PluginView: AnyObject {
    func update(_ view: EditorViewing, _ prevState: EditorState)
    func destroy()
}

public extension PluginView {
    func update(_ view: EditorViewing, _ prevState: EditorState) {}
    func destroy() {}
}

/// A plugin state field. `Value` is the type of the stored state.
public struct StateField<Value> {
    public var initialize: (_ config: EditorState.Config, _ state: EditorState) -> Value
    public var apply: (_ tr: Transaction, _ value: Value, _ oldState: EditorState, _ newState: EditorState) -> Value
    public var toJSON: ((Value) -> JSON)?
    public var fromJSON: ((_ config: EditorState.Config, _ json: JSON, _ state: EditorState) throws -> Value)?

    public init(initialize: @escaping (EditorState.Config, EditorState) -> Value,
                apply: @escaping (Transaction, Value, EditorState, EditorState) -> Value,
                toJSON: ((Value) -> JSON)? = nil,
                fromJSON: ((EditorState.Config, JSON, EditorState) throws -> Value)? = nil) {
        self.initialize = initialize; self.apply = apply; self.toJSON = toJSON; self.fromJSON = fromJSON
    }

    func erased() -> StateField<Any> {
        StateField<Any>(
            initialize: initialize,
            apply: { tr, v, o, n in apply(tr, v as! Value, o, n) },
            toJSON: toJSON.map { f in { f($0 as! Value) } },
            fromJSON: fromJSON)
    }
}

final class KeyNames: @unchecked Sendable {
    static let shared = KeyNames()
    private var counts: [String: Int] = [:]
    private let lock = NSLock()
    func create(_ name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = counts[name] { counts[name] = n + 1; return "\(name)$\(n + 1)" }
        counts[name] = 0
        return "\(name)$"
    }
}

/// A key that identifies a plugin and gives typed access to its state.
public final class PluginKey<Value>: MetaKey {
    public let key: String
    public init(_ name: String = "key") { key = KeyNames.shared.create(name) }
    public var metaKey: String { key }
    public func get(_ state: EditorState) -> Plugin? { state.config.pluginsByKey[key] }
    public func getState(_ state: EditorState) -> Value? { state.fields[key] as? Value }
}

/// A plugin extends the editor with state, props, transaction filters, and appended transactions.
public final class Plugin: MetaKey {
    public typealias FilterTransaction = (_ tr: Transaction, _ state: EditorState) -> Bool
    public typealias AppendTransaction = (_ trs: [Transaction], _ oldState: EditorState, _ newState: EditorState) -> Transaction?

    public let key: String
    public let props: EditorProps
    let state: StateField<Any>?
    public let filterTransaction: FilterTransaction?
    public let appendTransaction: AppendTransaction?
    public let view: ((EditorViewing) -> PluginView)?
    /// Extra values for plugins that need to expose more (for example the input rules list).
    public let extra: [String: Any]

    public init<Value>(key: PluginKey<Value>? = nil,
                       state: StateField<Value>? = nil,
                       props: EditorProps = EditorProps(),
                       filterTransaction: FilterTransaction? = nil,
                       appendTransaction: AppendTransaction? = nil,
                       view: ((EditorViewing) -> PluginView)? = nil,
                       extra: [String: Any] = [:]) {
        self.key = key?.key ?? KeyNames.shared.create("plugin")
        self.state = state?.erased()
        self.props = props
        self.filterTransaction = filterTransaction
        self.appendTransaction = appendTransaction
        self.view = view
        self.extra = extra
    }

    /// A plugin without state.
    public convenience init(props: EditorProps = EditorProps(),
                            filterTransaction: FilterTransaction? = nil,
                            appendTransaction: AppendTransaction? = nil,
                            view: ((EditorViewing) -> PluginView)? = nil,
                            extra: [String: Any] = [:]) {
        self.init(key: nil as PluginKey<Never>?, state: nil as StateField<Never>?, props: props,
                  filterTransaction: filterTransaction, appendTransaction: appendTransaction, view: view, extra: extra)
    }

    public var metaKey: String { key }

    public func getState(_ state: EditorState) -> Any? { state.fields[key] }
    public func getState<T>(_ state: EditorState, as: T.Type) -> T? { state.fields[key] as? T }
}
