/// The immutable state of an editor: document, selection, stored marks, and plugin state.
public final class EditorState {
    /// Options for ``create(_:)``.
    public struct Config {
        public var schema: Schema?
        public var doc: Node?
        public var selection: Selection?
        public var storedMarks: [Mark]?
        public var plugins: [Plugin]
        public init(schema: Schema? = nil, doc: Node? = nil, selection: Selection? = nil,
                    storedMarks: [Mark]? = nil, plugins: [Plugin] = []) {
            self.schema = schema; self.doc = doc; self.selection = selection
            self.storedMarks = storedMarks; self.plugins = plugins
        }
    }

    final class Configuration {
        let schema: Schema
        let plugins: [Plugin]
        let pluginsByKey: [String: Plugin]
        init(_ schema: Schema, _ plugins: [Plugin]) throws {
            var byKey: [String: Plugin] = [:]
            for p in plugins {
                if byKey[p.key] != nil { throw ProseError.range("Adding different instances of a keyed plugin (\(p.key))") }
                byKey[p.key] = p
            }
            self.schema = schema; self.plugins = plugins; pluginsByKey = byKey
        }
    }

    let config: Configuration
    public private(set) var doc: Node
    public private(set) var selection: Selection
    public private(set) var storedMarks: [Mark]?
    /// Increments each time a transaction asks to scroll the selection into view.
    public private(set) var scrollToSelection = 0
    /// Plugin state by plugin key.
    var fields: [String: Any] = [:]

    private init(_ config: Configuration, doc: Node, selection: Selection) {
        self.config = config; self.doc = doc; self.selection = selection
    }

    public var schema: Schema { config.schema }
    public var plugins: [Plugin] { config.plugins }

    /// Start a transaction from this state.
    public var tr: Transaction { Transaction(self) }

    public static func create(_ c: Config) throws -> EditorState {
        guard let schema = c.doc?.type.schema ?? c.schema else { throw ProseError.range("EditorState.create needs a doc or a schema") }
        let conf = try Configuration(schema, c.plugins)
        guard let doc = c.doc ?? schema.topNodeType.createAndFill() else { throw ProseError.range("Cannot create a default document") }
        let state = EditorState(conf, doc: doc, selection: c.selection ?? Selection.atStart(doc))
        state.storedMarks = c.storedMarks
        for p in conf.plugins { if let f = p.state { state.fields[p.key] = f.initialize(c, state) } }
        return state
    }

    /// Apply a transaction, including transactions that plugins append.
    public func apply(_ tr: Transaction) throws -> EditorState { try applyTransaction(tr).state }

    func filterTransaction(_ tr: Transaction, ignore: Int = -1) -> Bool {
        for (i, p) in config.plugins.enumerated() where i != ignore {
            if let f = p.filterTransaction, !f(tr, self) { return false }
        }
        return true
    }

    /// Apply a transaction and return the new state plus every transaction that was applied.
    public func applyTransaction(_ rootTr: Transaction) throws -> (state: EditorState, transactions: [Transaction]) {
        if !filterTransaction(rootTr) { return (self, []) }
        var trs = [rootTr]
        var newState = try applyInner(rootTr)
        var seen: [(state: EditorState, n: Int)]?
        while true {
            var haveNew = false
            for (i, plugin) in config.plugins.enumerated() {
                guard let append = plugin.appendTransaction else { continue }
                let n = seen?[i].n ?? 0, oldState = seen?[i].state ?? self
                let tr = n < trs.count ? append(n > 0 ? Array(trs[n...]) : trs, oldState, newState) : nil
                if let tr, newState.filterTransaction(tr, ignore: i) {
                    tr.setMeta("appendedTransaction", rootTr)
                    if seen == nil {
                        seen = (0..<config.plugins.count).map { j in j < i ? (newState, trs.count) : (self, 0) }
                    }
                    trs.append(tr)
                    newState = try newState.applyInner(tr)
                    haveNew = true
                }
                if seen != nil { seen![i] = (newState, trs.count) }
            }
            if !haveNew { return (newState, trs) }
        }
    }

    func applyInner(_ tr: Transaction) throws -> EditorState {
        guard tr.before.eq(doc) else { throw ProseError.range("Applying a mismatched transaction") }
        let next = EditorState(config, doc: tr.doc, selection: tr.selection)
        next.storedMarks = (next.selection as? TextSelection)?.cursor != nil ? tr.storedMarks : nil
        next.scrollToSelection = tr.scrolledIntoView ? scrollToSelection + 1 : scrollToSelection
        for p in config.plugins {
            if let f = p.state { next.fields[p.key] = f.apply(tr, fields[p.key] as Any, self, next) }
        }
        return next
    }

    /// Create a state with a different set of plugins. Existing plugins keep their state.
    public func reconfigure(plugins: [Plugin]) throws -> EditorState {
        let conf = try Configuration(schema, plugins)
        let next = EditorState(conf, doc: doc, selection: selection)
        next.storedMarks = storedMarks
        next.scrollToSelection = scrollToSelection
        let c = Config(schema: schema, doc: doc, selection: selection, storedMarks: storedMarks, plugins: plugins)
        for p in plugins {
            guard let f = p.state else { continue }
            next.fields[p.key] = fields[p.key] ?? f.initialize(c, next)
        }
        return next
    }

    /// Serialise the state. `pluginFields` maps JSON property names to plugins whose state should be included.
    public func toJSON(pluginFields: [String: Plugin] = [:]) throws -> JSON {
        var result: [String: JSON] = ["doc": doc.toJSON(), "selection": selection.toJSON()]
        if let storedMarks { result["storedMarks"] = .array(storedMarks.map { $0.toJSON() }) }
        for (prop, plugin) in pluginFields {
            if prop == "doc" || prop == "selection" { throw ProseError.range("The JSON fields `doc` and `selection` are reserved") }
            if let f = plugin.state?.toJSON, let v = fields[plugin.key] { result[prop] = f(v) }
        }
        return .object(result)
    }

    /// Deserialise a state. The document is validated against the schema.
    public static func fromJSON(schema: Schema, plugins: [Plugin] = [], _ json: JSON,
                                pluginFields: [String: Plugin] = [:]) throws -> EditorState {
        guard let docJSON = json["doc"], let selJSON = json["selection"] else {
            throw ProseError.range("Invalid input for EditorState.fromJSON")
        }
        let conf = try Configuration(schema, plugins)
        let doc = try schema.nodeFromJSON(docJSON, validate: true)
        let state = EditorState(conf, doc: doc, selection: try Selection.fromJSON(doc, selJSON))
        if let m = json["storedMarks"]?.arrayValue { state.storedMarks = try m.map(schema.markFromJSON) }
        let c = Config(schema: schema, doc: doc, selection: state.selection, storedMarks: state.storedMarks, plugins: plugins)
        for p in plugins {
            guard let f = p.state else { continue }
            if let (prop, _) = pluginFields.first(where: { $0.value.key == p.key }), let fromJSON = f.fromJSON, let v = json[prop] {
                state.fields[p.key] = try fromJSON(c, v, state)
            } else {
                state.fields[p.key] = f.initialize(c, state)
            }
        }
        return state
    }
}
