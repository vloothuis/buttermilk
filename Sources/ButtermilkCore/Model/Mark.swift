/// A mark is a piece of information attached to inline content, such as emphasis or a link.
public struct Mark: Hashable, CustomStringConvertible {
    public let type: MarkType
    public let attrs: Attrs

    public init(type: MarkType, attrs: Attrs) {
        self.type = type
        self.attrs = attrs
    }

    /// Add this mark to a set, respecting exclusion and rank order.
    public func addToSet(_ set: [Mark]) -> [Mark] {
        var copy: [Mark]?
        var placed = false
        for (i, other) in set.enumerated() {
            if self == other { return set }
            if type.excludes(other.type) {
                if copy == nil { copy = Array(set[0..<i]) }
            } else if other.type.excludes(type) {
                return set
            } else {
                if !placed && other.type.rank > type.rank {
                    if copy == nil { copy = Array(set[0..<i]) }
                    copy!.append(self)
                    placed = true
                }
                if copy != nil { copy!.append(other) }
            }
        }
        var result = copy ?? set
        if !placed { result.append(self) }
        return result
    }

    public func removeFromSet(_ set: [Mark]) -> [Mark] {
        guard let i = set.firstIndex(of: self) else { return set }
        var copy = set
        copy.remove(at: i)
        return copy
    }

    public func isInSet(_ set: [Mark]) -> Bool { set.contains(self) }

    public func toJSON() -> JSON {
        var obj: [String: JSON] = ["type": .string(type.name)]
        if !attrs.isEmpty { obj["attrs"] = .object(attrs) }
        return .object(obj)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Mark {
        guard let name = json["type"]?.stringValue else { throw ProseError.range("Invalid input for Mark.fromJSON") }
        guard let type = schema.marks[name] else { throw ProseError.range("There is no mark type \(name) in this schema") }
        return try type.create(json["attrs"]?.objectValue)
    }

    public static func sameSet(_ a: [Mark], _ b: [Mark]) -> Bool { a == b }

    /// Create a properly sorted mark set.
    public static func setFrom(_ marks: [Mark]) -> [Mark] {
        marks.count <= 1 ? marks : marks.sorted { $0.type.rank < $1.type.rank }
    }

    public static let none: [Mark] = []

    public var description: String { type.name }

    public static func == (a: Mark, b: Mark) -> Bool { a.type === b.type && a.attrs == b.attrs }
    public func hash(into h: inout Hasher) { h.combine(type); h.combine(attrs) }
}
