/// Describes an attribute of a node or mark type.
public struct AttributeSpec {
    /// The default value. `nil` means the attribute is required. Use `.null` for a `null` default.
    public var `default`: JSON?
    /// Validation run when a value is supplied.
    public var validate: ((JSON) throws -> Void)?

    public init(default: JSON? = nil, validate: ((JSON) throws -> Void)? = nil) {
        self.default = `default`
        self.validate = validate
    }

    /// Validate the JS-style type name of the value, for example `"string|null"`.
    public init(default: JSON? = nil, validateType: String) {
        self.default = `default`
        let types = validateType.split(separator: "|").map(String.init)
        self.validate = { value in
            if !types.contains(value.typeName) {
                throw ProseError.range("Expected value of type \(types.joined(separator: ",")) for attribute, got \(value.typeName)")
            }
        }
        self.validateTypeName = validateType
    }

    var validateTypeName: String?
}

public enum Whitespace: String, Sendable { case pre, normal }

/// Describes a node type.
public struct NodeSpec {
    public var content: String?
    public var marks: String?
    public var group: String?
    public var inline: Bool = false
    public var atom: Bool = false
    public var attrs: [String: AttributeSpec] = [:]
    public var selectable: Bool?
    public var draggable: Bool = false
    public var code: Bool = false
    public var whitespace: Whitespace?
    public var definingAsContext: Bool?
    public var definingForContent: Bool?
    public var defining: Bool = false
    public var isolating: Bool = false
    public var linebreakReplacement: Bool = false
    public var toDebugString: ((Node) -> String)?
    public var leafText: ((Node) -> String)?
    /// Arbitrary extra data, available to plugins and higher layers.
    public var extra: [String: Any] = [:]

    public init(content: String? = nil, marks: String? = nil, group: String? = nil, inline: Bool = false,
                atom: Bool = false, attrs: [String: AttributeSpec] = [:], selectable: Bool? = nil,
                draggable: Bool = false, code: Bool = false, whitespace: Whitespace? = nil,
                definingAsContext: Bool? = nil, definingForContent: Bool? = nil, defining: Bool = false,
                isolating: Bool = false, linebreakReplacement: Bool = false,
                toDebugString: ((Node) -> String)? = nil, leafText: ((Node) -> String)? = nil,
                extra: [String: Any] = [:]) {
        self.content = content; self.marks = marks; self.group = group; self.inline = inline
        self.atom = atom; self.attrs = attrs; self.selectable = selectable; self.draggable = draggable
        self.code = code; self.whitespace = whitespace; self.definingAsContext = definingAsContext
        self.definingForContent = definingForContent; self.defining = defining; self.isolating = isolating
        self.linebreakReplacement = linebreakReplacement; self.toDebugString = toDebugString
        self.leafText = leafText; self.extra = extra
    }
}

/// Describes a mark type.
public struct MarkSpec {
    public var attrs: [String: AttributeSpec] = [:]
    public var inclusive: Bool?
    public var excludes: String?
    public var group: String?
    public var spanning: Bool?
    public var code: Bool = false
    public var extra: [String: Any] = [:]

    public init(attrs: [String: AttributeSpec] = [:], inclusive: Bool? = nil, excludes: String? = nil,
                group: String? = nil, spanning: Bool? = nil, code: Bool = false, extra: [String: Any] = [:]) {
        self.attrs = attrs; self.inclusive = inclusive; self.excludes = excludes; self.group = group
        self.spanning = spanning; self.code = code; self.extra = extra
    }
}

/// An attribute descriptor compiled from an ``AttributeSpec``.
public struct Attribute {
    public let hasDefault: Bool
    public let defaultValue: JSON?
    public let validate: ((JSON) throws -> Void)?
    public var isRequired: Bool { !hasDefault }

    init(_ spec: AttributeSpec) {
        hasDefault = spec.default != nil
        defaultValue = spec.default
        validate = spec.validate
    }
}

func defaultAttrs(_ attrs: [String: Attribute]) -> Attrs? {
    var result: Attrs = [:]
    for (name, attr) in attrs {
        guard let d = attr.defaultValue else { return nil }
        result[name] = d
    }
    return result
}

func computeAttrs(_ attrs: [String: Attribute], _ value: Attrs?) throws -> Attrs {
    var built: Attrs = [:]
    for (name, attr) in attrs {
        if let given = value?[name] {
            try attr.validate?(given)
            built[name] = given
        } else if let d = attr.defaultValue {
            built[name] = d
        } else {
            throw ProseError.range("No value supplied for attribute \(name)")
        }
    }
    return built
}

func checkAttrs(_ attrs: [String: Attribute], _ values: Attrs, _ kind: String, _ name: String) throws {
    for key in values.keys where attrs[key] == nil {
        throw ProseError.range("Unsupported attribute \(key) for \(kind) of type \(name)")
    }
    for (key, attr) in attrs {
        if let v = attr.validate { try v(values[key] ?? .null) }
    }
}

/// A node type. Each node in a document has a type, which is part of a ``Schema``.
public final class NodeType: Hashable, CustomStringConvertible {
    public let name: String
    public unowned let schema: Schema
    public let spec: NodeSpec
    public let groups: [String]
    public let attrs: [String: Attribute]
    public let defaultAttrs: Attrs?
    public let isBlock: Bool
    public let isText: Bool
    public internal(set) var inlineContent = false
    public internal(set) var contentMatch: ContentMatch = .empty
    /// The allowed marks, or `nil` when all marks are allowed.
    public internal(set) var markSet: [MarkType]?

    init(name: String, schema: Schema, spec: NodeSpec) {
        self.name = name
        self.schema = schema
        self.spec = spec
        self.groups = spec.group.map { $0.split(separator: " ").map(String.init) } ?? []
        self.attrs = spec.attrs.mapValues(Attribute.init)
        self.defaultAttrs = ButtermilkCore.defaultAttrs(self.attrs)
        self.isBlock = !(spec.inline || name == "text")
        self.isText = name == "text"
    }

    public var isInline: Bool { !isBlock }
    public var isTextblock: Bool { isBlock && inlineContent }
    public var isLeaf: Bool { contentMatch === ContentMatch.empty }
    public var isAtom: Bool { isLeaf || spec.atom }
    public var whitespace: Whitespace { spec.whitespace ?? (spec.code ? .pre : .normal) }
    public var description: String { name }

    public func isInGroup(_ group: String) -> Bool { groups.contains(group) }

    public func hasRequiredAttrs() -> Bool { attrs.values.contains { $0.isRequired } }

    public func compatibleContent(_ other: NodeType) -> Bool {
        self === other || contentMatch.compatible(other.contentMatch)
    }

    public func computeAttrs(_ attrs: Attrs?) throws -> Attrs {
        if attrs == nil, let d = defaultAttrs { return d }
        return try ButtermilkCore.computeAttrs(self.attrs, attrs)
    }

    /// Create a node of this type. Content is not checked.
    public func create(_ attrs: Attrs? = nil, _ content: Fragment = .empty, marks: [Mark] = []) throws -> Node {
        precondition(!isText, "NodeType.create can't construct text nodes")
        return Node(type: self, attrs: try computeAttrs(attrs), content: content, marks: Mark.setFrom(marks))
    }

    public func create(_ attrs: Attrs? = nil, _ content: [Node], marks: [Mark] = []) throws -> Node {
        try create(attrs, Fragment.from(content), marks: marks)
    }

    public func create(_ attrs: Attrs? = nil, _ content: Node, marks: [Mark] = []) throws -> Node {
        try create(attrs, Fragment(content), marks: marks)
    }

    /// Create a node of this type, checking its content.
    public func createChecked(_ attrs: Attrs? = nil, _ content: Fragment = .empty, marks: [Mark] = []) throws -> Node {
        try checkContent(content)
        return Node(type: self, attrs: try computeAttrs(attrs), content: content, marks: Mark.setFrom(marks))
    }

    /// Create a node, adding nodes to the start or end of the content to make it valid.
    /// Returns `nil` when no valid node can be built.
    public func createAndFill(_ attrs: Attrs? = nil, _ content: Fragment = .empty, marks: [Mark] = []) -> Node? {
        guard let attrs = try? computeAttrs(attrs) else { return nil }
        var content = content
        if content.size > 0 {
            guard let before = contentMatch.fillBefore(content) else { return nil }
            content = before.append(content)
        }
        guard let matched = contentMatch.matchFragment(content),
              let after = matched.fillBefore(.empty, toEnd: true) else { return nil }
        return Node(type: self, attrs: attrs, content: content.append(after), marks: Mark.setFrom(marks))
    }

    public func validContent(_ content: Fragment) -> Bool {
        guard let result = contentMatch.matchFragment(content), result.validEnd else { return false }
        for child in content.children where !allowsMarks(child.marks) { return false }
        return true
    }

    public func checkContent(_ content: Fragment) throws {
        if !validContent(content) {
            throw ProseError.range("Invalid content for node \(name): \(String(content.description.prefix(50)))")
        }
    }

    public func allowsMarkType(_ markType: MarkType) -> Bool {
        markSet.map { $0.contains { $0 === markType } } ?? true
    }

    public func allowsMarks(_ marks: [Mark]) -> Bool {
        guard markSet != nil else { return true }
        return marks.allSatisfy { allowsMarkType($0.type) }
    }

    public func allowedMarks(_ marks: [Mark]) -> [Mark] {
        guard markSet != nil else { return marks }
        return marks.filter { allowsMarkType($0.type) }
    }

    public static func == (a: NodeType, b: NodeType) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// A mark type. Like nodes, marks have a type which is part of a ``Schema``.
public final class MarkType: Hashable, CustomStringConvertible {
    public let name: String
    public let rank: Int
    public unowned let schema: Schema
    public let spec: MarkSpec
    public let attrs: [String: Attribute]
    public internal(set) var excluded: [MarkType] = []

    init(name: String, rank: Int, schema: Schema, spec: MarkSpec) {
        self.name = name
        self.rank = rank
        self.schema = schema
        self.spec = spec
        self.attrs = spec.attrs.mapValues(Attribute.init)
        _instanceAttrs = ButtermilkCore.defaultAttrs(self.attrs)
    }

    private let _instanceAttrs: Attrs?
    public var description: String { name }

    /// Create a mark of this type.
    public func create(_ attrs: Attrs? = nil) throws -> Mark {
        if attrs == nil, let d = _instanceAttrs { return Mark(type: self, attrs: d) }
        return Mark(type: self, attrs: try computeAttrs(self.attrs, attrs))
    }

    /// Create a mark with default attributes. Traps when the type has required attributes.
    public func create() -> Mark {
        try! create(nil)
    }

    public func removeFromSet(_ set: [Mark]) -> [Mark] { set.filter { $0.type !== self } }

    public func isInSet(_ set: [Mark]) -> Mark? { set.first { $0.type === self } }

    public func excludes(_ other: MarkType) -> Bool { excluded.contains { $0 === other } }

    public static func == (a: MarkType, b: MarkType) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// A document schema: the node and mark types that may occur in a document.
public final class Schema {
    public let nodeSpecs: [(name: String, spec: NodeSpec)]
    public let markSpecs: [(name: String, spec: MarkSpec)]
    public let topNodeName: String
    public private(set) var nodes: [String: NodeType] = [:]
    public private(set) var marks: [String: MarkType] = [:]
    /// Node and mark types in spec order.
    public private(set) var nodeTypes: [NodeType] = []
    public private(set) var markTypes: [MarkType] = []
    public private(set) var linebreakReplacement: NodeType?
    public private(set) var topNodeType: NodeType!
    /// Storage for plugins that want to cache data per schema.
    public var cached: [String: Any] = [:]

    public convenience init(nodes: KeyValuePairs<String, NodeSpec>, marks: KeyValuePairs<String, MarkSpec> = [:],
                            topNode: String = "doc") throws {
        try self.init(nodeList: nodes.map { ($0.key, $0.value) }, markList: marks.map { ($0.key, $0.value) },
                      topNode: topNode)
    }

    public init(nodeList: [(String, NodeSpec)], markList: [(String, MarkSpec)] = [], topNode: String = "doc") throws {
        nodeSpecs = nodeList.map { (name: $0.0, spec: $0.1) }
        markSpecs = markList.map { (name: $0.0, spec: $0.1) }
        topNodeName = topNode

        for (name, spec) in nodeSpecs {
            let t = NodeType(name: name, schema: self, spec: spec)
            nodes[name] = t
            nodeTypes.append(t)
        }
        guard let top = nodes[topNode] else {
            throw ProseError.range("Schema is missing its top node type ('\(topNode)')")
        }
        guard let text = nodes["text"] else { throw ProseError.range("Every schema needs a 'text' type") }
        if !text.attrs.isEmpty { throw ProseError.range("The text node type should not have attributes") }
        for (i, (name, spec)) in markSpecs.enumerated() {
            let t = MarkType(name: name, rank: i, schema: self, spec: spec)
            marks[name] = t
            markTypes.append(t)
        }

        var cache: [String: ContentMatch] = [:]
        for type in nodeTypes {
            if marks[type.name] != nil { throw ProseError.range("\(type.name) can not be both a node and a mark") }
            let expr = type.spec.content ?? ""
            if let m = cache[expr] { type.contentMatch = m } else {
                let m = try ContentMatch.parse(expr, nodeTypes: nodeTypes, byName: nodes)
                cache[expr] = m
                type.contentMatch = m
            }
            type.inlineContent = type.contentMatch.inlineContent
            if type.spec.linebreakReplacement {
                if linebreakReplacement != nil { throw ProseError.range("Multiple linebreak nodes defined") }
                if !type.isInline || !type.isLeaf {
                    throw ProseError.range("Linebreak replacement nodes must be inline leaf nodes")
                }
                linebreakReplacement = type
            }
            let markExpr = type.spec.marks
            if markExpr == "_" { type.markSet = nil }
            else if let markExpr, !markExpr.isEmpty {
                type.markSet = try gatherMarks(markExpr.split(separator: " ").map(String.init))
            } else if markExpr == "" || !type.inlineContent { type.markSet = [] }
            else { type.markSet = nil }
        }
        for type in markTypes {
            if let excl = type.spec.excludes {
                type.excluded = excl.isEmpty ? [] : try gatherMarks(excl.split(separator: " ").map(String.init))
            } else {
                type.excluded = [type]
            }
        }
        topNodeType = top
    }

    private func gatherMarks(_ names: [String]) throws -> [MarkType] {
        var found: [MarkType] = []
        for name in names {
            if let m = marks[name] { found.append(m); continue }
            var ok = false
            for m in markTypes where name == "_" || (m.spec.group?.split(separator: " ").contains { $0 == name } ?? false) {
                found.append(m)
                ok = true
            }
            if !ok { throw ProseError.syntax("Unknown mark type: '\(name)'") }
        }
        return found
    }

    /// Create a node, checking its content.
    public func node(_ type: String, _ attrs: Attrs? = nil, _ content: [Node] = [], marks: [Mark] = []) throws -> Node {
        try nodeType(type).createChecked(attrs, Fragment.from(content), marks: marks)
    }

    public func node(_ type: NodeType, _ attrs: Attrs? = nil, _ content: [Node] = [], marks: [Mark] = []) throws -> Node {
        precondition(type.schema === self, "Node type from different schema used (\(type.name))")
        return try type.createChecked(attrs, Fragment.from(content), marks: marks)
    }

    /// Create a text node. The text must not be empty.
    public func text(_ text: String, marks: [Mark] = []) -> Node {
        precondition(!text.isEmpty, "Empty text nodes are not allowed")
        let type = nodes["text"]!
        return Node(type: type, attrs: [:], text: text, marks: Mark.setFrom(marks))
    }

    public func mark(_ name: String, _ attrs: Attrs? = nil) throws -> Mark {
        guard let t = marks[name] else { throw ProseError.range("There is no mark type \(name) in this schema") }
        return try t.create(attrs)
    }

    public func nodeType(_ name: String) throws -> NodeType {
        guard let t = nodes[name] else { throw ProseError.range("Unknown node type: \(name)") }
        return t
    }

    /// Deserialise a node. Like ProseMirror, this does not check content against the schema
    /// unless `validate` is true. Pass `true` for untrusted input: operations on a node with
    /// invalid content can trap.
    public func nodeFromJSON(_ json: JSON, validate: Bool = false) throws -> Node {
        let node = try Node.fromJSON(self, json)
        if validate { try node.check() }
        return node
    }
    public func markFromJSON(_ json: JSON) throws -> Mark { try Mark.fromJSON(self, json) }
}
