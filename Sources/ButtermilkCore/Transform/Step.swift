/// The result of applying a step: a new document or a failure message.
public struct StepResult {
    public let doc: Node?
    public let failed: String?

    public static func ok(_ doc: Node) -> StepResult { StepResult(doc: doc, failed: nil) }
    public static func fail(_ message: String) -> StepResult { StepResult(doc: nil, failed: message) }

    public static func fromReplace(_ doc: Node, _ from: Int, _ to: Int, _ slice: Slice) -> StepResult {
        do { return .ok(try doc.replace(from, to, slice)) }
        catch let ProseError.replace(message) { return .fail(message) }
        catch { return .fail("\(error)") }
    }
}

/// An atomic change to a document. Steps can be applied, inverted, mapped, and serialised.
public protocol Step: AnyObject, CustomStringConvertible {
    /// The identifier used in the step's JSON representation.
    static var jsonID: String { get }
    func apply(_ doc: Node) -> StepResult
    func getMap() -> StepMap
    func invert(_ doc: Node) -> Step
    func map(_ mapping: Mappable) -> Step?
    func merge(_ other: Step) -> Step?
    func toJSON() -> JSON
}

public extension Step {
    func getMap() -> StepMap { .empty }
    func merge(_ other: Step) -> Step? { nil }
    var description: String { toJSON().serialized() }
}

/// Deserialises steps by their `stepType`. Register custom steps with ``register(_:_:)``.
public enum StepRegistry {
    public typealias Decoder = (Schema, JSON) throws -> Step
    nonisolated(unsafe) private static var decoders: [String: Decoder] = [
        ReplaceStep.jsonID: ReplaceStep.fromJSON,
        ReplaceAroundStep.jsonID: ReplaceAroundStep.fromJSON,
        AddMarkStep.jsonID: AddMarkStep.fromJSON,
        RemoveMarkStep.jsonID: RemoveMarkStep.fromJSON,
        MarkSetStep.jsonID: MarkSetStep.fromJSON,
        AddNodeMarkStep.jsonID: AddNodeMarkStep.fromJSON,
        RemoveNodeMarkStep.jsonID: RemoveNodeMarkStep.fromJSON,
        AttrStep.jsonID: AttrStep.fromJSON,
        DocAttrStep.jsonID: DocAttrStep.fromJSON,
    ]

    public static func register(_ id: String, _ decoder: @escaping Decoder) {
        precondition(decoders[id] == nil, "Duplicate use of step JSON ID \(id)")
        decoders[id] = decoder
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let id = json["stepType"]?.stringValue else { throw ProseError.range("Invalid input for Step.fromJSON") }
        guard let d = decoders[id] else { throw ProseError.range("No step type \(id) defined") }
        return try d(schema, json)
    }
}

private func num(_ json: JSON, _ key: String) -> Int? { json[key]?.intValue }

/// True when the positions are ordered and lie inside the document. Steps can come from
/// untrusted JSON, so `apply` checks this instead of trapping.
func positionsValid(_ doc: Node, _ positions: Int...) -> Bool {
    var last = 0
    for p in positions { if p < last || p > doc.content.size { return false }; last = p }
    return true
}

// MARK: - Replace steps

public final class ReplaceStep: Step {
    public static let jsonID = "replace"
    public let from: Int, to: Int
    public let slice: Slice
    public let structure: Bool

    public init(_ from: Int, _ to: Int, _ slice: Slice, structure: Bool = false) {
        self.from = from; self.to = to; self.slice = slice; self.structure = structure
    }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, from, to) else { return .fail("Step position out of range") }
        if structure && contentBetween(doc, from, to) { return .fail("Structure replace would overwrite content") }
        return .fromReplace(doc, from, to, slice)
    }

    public func getMap() -> StepMap { StepMap([from, to - from, slice.size]) }

    public func invert(_ doc: Node) -> Step { ReplaceStep(from, from + slice.size, doc.slice(from, to)) }

    public func map(_ mapping: Mappable) -> Step? {
        let to = mapping.mapResult(self.to, assoc: -1)
        let from = self.from == self.to && ReplaceStep.mapBias < 0 ? to : mapping.mapResult(self.from, assoc: 1)
        if from.deletedAcross && to.deletedAcross { return nil }
        return ReplaceStep(from.pos, max(from.pos, to.pos), slice, structure: structure)
    }

    public func merge(_ other: Step) -> Step? {
        guard let other = other as? ReplaceStep, !other.structure, !structure else { return nil }
        if from + slice.size == other.from && slice.openEnd == 0 && other.slice.openStart == 0 {
            let s = slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(slice.content.append(other.slice.content), openStart: slice.openStart, openEnd: other.slice.openEnd)
            return ReplaceStep(from, to + (other.to - other.from), s, structure: structure)
        } else if other.to == from && slice.openStart == 0 && other.slice.openEnd == 0 {
            let s = slice.size + other.slice.size == 0 ? Slice.empty
                : Slice(other.slice.content.append(slice.content), openStart: other.slice.openStart, openEnd: slice.openEnd)
            return ReplaceStep(other.from, to, s, structure: structure)
        }
        return nil
    }

    public func toJSON() -> JSON {
        var json: [String: JSON] = ["stepType": "replace", "from": .number(Double(from)), "to": .number(Double(to))]
        if slice.size > 0, let s = slice.toJSON() { json["slice"] = s }
        if structure { json["structure"] = true }
        return .object(json)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let from = num(json, "from"), let to = num(json, "to") else {
            throw ProseError.range("Invalid input for ReplaceStep.fromJSON")
        }
        return ReplaceStep(from, to, try Slice.fromJSON(schema, json["slice"]), structure: json["structure"]?.boolValue ?? false)
    }

    /// Bias used when mapping zero-length replace steps.
    nonisolated(unsafe) public static var mapBias = 1
}

public final class ReplaceAroundStep: Step {
    public static let jsonID = "replaceAround"
    public let from: Int, to: Int, gapFrom: Int, gapTo: Int
    public let slice: Slice
    public let insert: Int
    public let structure: Bool

    public init(_ from: Int, _ to: Int, _ gapFrom: Int, _ gapTo: Int, _ slice: Slice, _ insert: Int, structure: Bool = false) {
        self.from = from; self.to = to; self.gapFrom = gapFrom; self.gapTo = gapTo
        self.slice = slice; self.insert = insert; self.structure = structure
    }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, from, gapFrom, gapTo, to) else { return .fail("Step position out of range") }
        if structure && (contentBetween(doc, from, gapFrom) || contentBetween(doc, gapTo, to)) {
            return .fail("Structure gap-replace would overwrite content")
        }
        let gap = doc.slice(gapFrom, gapTo)
        if gap.openStart > 0 || gap.openEnd > 0 { return .fail("Gap is not a flat range") }
        guard let inserted = slice.insertAt(insert, gap.content) else { return .fail("Content does not fit in gap") }
        return .fromReplace(doc, from, to, inserted)
    }

    public func getMap() -> StepMap {
        StepMap([from, gapFrom - from, insert, gapTo, to - gapTo, slice.size - insert])
    }

    public func invert(_ doc: Node) -> Step {
        let gap = gapTo - gapFrom
        return ReplaceAroundStep(from, from + slice.size + gap, from + insert, from + insert + gap,
                                 try! doc.slice(from, to).removeBetween(gapFrom - from, gapTo - from),
                                 gapFrom - from, structure: structure)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let from = mapping.mapResult(self.from, assoc: 1), to = mapping.mapResult(self.to, assoc: -1)
        let gapFrom = self.from == self.gapFrom ? from.pos : mapping.map(self.gapFrom, assoc: -1)
        let gapTo = self.to == self.gapTo ? to.pos : mapping.map(self.gapTo, assoc: 1)
        if (from.deletedAcross && to.deletedAcross) || gapFrom < from.pos || gapTo > to.pos || gapFrom > gapTo { return nil }
        return ReplaceAroundStep(from.pos, to.pos, gapFrom, gapTo, slice, insert, structure: structure)
    }

    public func toJSON() -> JSON {
        var json: [String: JSON] = [
            "stepType": "replaceAround", "from": .number(Double(from)), "to": .number(Double(to)),
            "gapFrom": .number(Double(gapFrom)), "gapTo": .number(Double(gapTo)), "insert": .number(Double(insert)),
        ]
        if slice.size > 0, let s = slice.toJSON() { json["slice"] = s }
        if structure { json["structure"] = true }
        return .object(json)
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let from = num(json, "from"), let to = num(json, "to"), let gapFrom = num(json, "gapFrom"),
              let gapTo = num(json, "gapTo"), let insert = num(json, "insert") else {
            throw ProseError.range("Invalid input for ReplaceAroundStep.fromJSON")
        }
        return ReplaceAroundStep(from, to, gapFrom, gapTo, try Slice.fromJSON(schema, json["slice"]), insert,
                                 structure: json["structure"]?.boolValue ?? false)
    }
}

func contentBetween(_ doc: Node, _ from: Int, _ to: Int) -> Bool {
    let rFrom = doc.resolve(from)
    var dist = to - from, depth = rFrom.depth
    while dist > 0 && depth > 0 && rFrom.indexAfter(depth) == rFrom.node(depth).childCount {
        depth -= 1
        dist -= 1
    }
    if dist > 0 {
        var next = rFrom.node(depth).maybeChild(rFrom.indexAfter(depth))
        while dist > 0 {
            guard let n = next, !n.isLeaf else { return true }
            next = n.firstChild
            dist -= 1
        }
    }
    return false
}

// MARK: - Mark steps

private func mapFragment(_ fragment: Fragment, _ parent: Node, _ f: (Node, Node, Int) -> Node) -> Fragment {
    var mapped: [Node] = []
    for i in 0..<fragment.childCount {
        var child = fragment.child(i)
        if child.content.size > 0 { child = child.copy(mapFragment(child.content, child, f)) }
        if child.isInline { child = f(child, parent, i) }
        mapped.append(child)
    }
    return Fragment.fromArray(mapped)
}

public final class AddMarkStep: Step {
    public static let jsonID = "addMark"
    public let from: Int, to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) { self.from = from; self.to = to; self.mark = mark }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, from, to) else { return .fail("Step position out of range") }
        let oldSlice = doc.slice(from, to), rFrom = doc.resolve(from)
        let parent = rFrom.node(rFrom.sharedDepth(to))
        let content = mapFragment(oldSlice.content, parent) { node, parent, _ in
            if !node.isAtom || !parent.type.allowsMarkType(self.mark.type) { return node }
            return node.mark(self.mark.addToSet(node.marks))
        }
        return .fromReplace(doc, from, to, Slice(content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd))
    }

    public func invert(_ doc: Node) -> Step {
        var steps: [MarkStep] = []
        doc.nodesBetween(from, to) { node, pos, _, _ in
            if node.isInline && node.isAtom {
                let added = self.mark.addToSet(node.marks)
                if added != node.marks {
                    let from = max(self.from, pos), to = min(self.to, pos + node.nodeSize)
                    pushMarkStep(.remove, from, to, self.mark, &steps)
                    for m in node.marks where !m.isInSet(added) { pushMarkStep(.add, from, to, m, &steps) }
                }
            }
            return true
        }
        return steps.count == 1 ? steps[0] : MarkSetStep(steps)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let from = mapping.map(self.from, assoc: 1), to = mapping.map(self.to, assoc: -1)
        if from >= to { return nil }
        return AddMarkStep(from, to, mark)
    }

    public func merge(_ other: Step) -> Step? {
        guard let other = other as? AddMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return AddMarkStep(min(from, other.from), max(to, other.to), mark)
    }

    public func toJSON() -> JSON {
        ["stepType": "addMark", "mark": mark.toJSON(), "from": .number(Double(from)), "to": .number(Double(to))]
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let from = num(json, "from"), let to = num(json, "to"), let m = json["mark"] else {
            throw ProseError.range("Invalid input for AddMarkStep.fromJSON")
        }
        return AddMarkStep(from, to, try schema.markFromJSON(m))
    }
}

public final class RemoveMarkStep: Step {
    public static let jsonID = "removeMark"
    public let from: Int, to: Int
    public let mark: Mark

    public init(_ from: Int, _ to: Int, _ mark: Mark) { self.from = from; self.to = to; self.mark = mark }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, from, to) else { return .fail("Step position out of range") }
        let oldSlice = doc.slice(from, to)
        let content = mapFragment(oldSlice.content, doc) { node, _, _ in node.mark(self.mark.removeFromSet(node.marks)) }
        return .fromReplace(doc, from, to, Slice(content, openStart: oldSlice.openStart, openEnd: oldSlice.openEnd))
    }

    public func invert(_ doc: Node) -> Step {
        var steps: [MarkStep] = []
        doc.nodesBetween(from, to) { node, pos, _, _ in
            if node.isInline && node.isAtom && self.mark.isInSet(node.marks) {
                pushMarkStep(.add, max(self.from, pos), min(self.to, pos + node.nodeSize), self.mark, &steps)
            }
            return true
        }
        return steps.count == 1 ? steps[0] : MarkSetStep(steps)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let from = mapping.map(self.from, assoc: 1), to = mapping.map(self.to, assoc: -1)
        if from >= to { return nil }
        return RemoveMarkStep(from, to, mark)
    }

    public func merge(_ other: Step) -> Step? {
        guard let other = other as? RemoveMarkStep, other.mark == mark, from <= other.to, to >= other.from else { return nil }
        return RemoveMarkStep(min(from, other.from), max(to, other.to), mark)
    }

    public func toJSON() -> JSON {
        ["stepType": "removeMark", "mark": mark.toJSON(), "from": .number(Double(from)), "to": .number(Double(to))]
    }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let from = num(json, "from"), let to = num(json, "to"), let m = json["mark"] else {
            throw ProseError.range("Invalid input for RemoveMarkStep.fromJSON")
        }
        return RemoveMarkStep(from, to, try schema.markFromJSON(m))
    }
}

/// Either an ``AddMarkStep`` or a ``RemoveMarkStep``.
public typealias MarkStep = Step

private enum MarkStepKind { case add, remove }

private func pushMarkStep(_ kind: MarkStepKind, _ from: Int, _ to: Int, _ mark: Mark, _ target: inout [MarkStep]) {
    func make(_ f: Int, _ t: Int) -> MarkStep { kind == .add ? AddMarkStep(f, t, mark) : RemoveMarkStep(f, t, mark) }
    if let last = target.last {
        if kind == .add, let l = last as? AddMarkStep, l.to == from, l.mark == mark {
            target[target.count - 1] = make(l.from, to); return
        }
        if kind == .remove, let l = last as? RemoveMarkStep, l.to == from, l.mark == mark {
            target[target.count - 1] = make(l.from, to); return
        }
    }
    target.append(make(from, to))
}

/// A group of mark steps applied together, used to invert mark steps over mixed content.
public final class MarkSetStep: Step {
    public static let jsonID = "markSet"
    public let steps: [MarkStep]

    public init(_ steps: [MarkStep]) { self.steps = steps }

    public func apply(_ doc: Node) -> StepResult {
        var doc = doc
        for step in steps {
            let result = step.apply(doc)
            guard let d = result.doc else { return result }
            doc = d
        }
        return .ok(doc)
    }

    public func invert(_ doc: Node) -> Step { MarkSetStep(steps.map { $0.invert(doc) }) }

    public func map(_ mapping: Mappable) -> Step? {
        let result = steps.compactMap { $0.map(mapping) }
        return result.isEmpty ? nil : MarkSetStep(result)
    }

    public func toJSON() -> JSON { ["stepType": "markSet", "steps": .array(steps.map { $0.toJSON() })] }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let arr = json["steps"]?.arrayValue,
              arr.allSatisfy({ $0["stepType"] == "addMark" || $0["stepType"] == "removeMark" }) else {
            throw ProseError.range("Invalid JSON for MarkSetStep")
        }
        return MarkSetStep(try arr.map { try StepRegistry.fromJSON(schema, $0) })
    }
}

public final class AddNodeMarkStep: Step {
    public static let jsonID = "addNodeMark"
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) { self.pos = pos; self.mark = mark }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, pos), let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        let updated = Node(type: node.type, attrs: node.attrs, content: .empty, marks: mark.addToSet(node.marks))
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> Step {
        if let node = doc.nodeAt(pos) {
            let newSet = mark.addToSet(node.marks)
            if newSet.count == node.marks.count {
                for m in node.marks where !m.isInSet(newSet) { return AddNodeMarkStep(pos, m) }
                return AddNodeMarkStep(pos, mark)
            }
        }
        return RemoveNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, assoc: 1)
        return p.deletedAfter ? nil : AddNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> JSON { ["stepType": "addNodeMark", "pos": .number(Double(pos)), "mark": mark.toJSON()] }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let pos = num(json, "pos"), let m = json["mark"] else {
            throw ProseError.range("Invalid input for AddNodeMarkStep.fromJSON")
        }
        return AddNodeMarkStep(pos, try schema.markFromJSON(m))
    }
}

public final class RemoveNodeMarkStep: Step {
    public static let jsonID = "removeNodeMark"
    public let pos: Int
    public let mark: Mark

    public init(_ pos: Int, _ mark: Mark) { self.pos = pos; self.mark = mark }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, pos), let node = doc.nodeAt(pos) else { return .fail("No node at mark step's position") }
        let updated = Node(type: node.type, attrs: node.attrs, content: .empty, marks: mark.removeFromSet(node.marks))
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment(updated), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> Step {
        guard let node = doc.nodeAt(pos), mark.isInSet(node.marks) else { return self }
        return AddNodeMarkStep(pos, mark)
    }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, assoc: 1)
        return p.deletedAfter ? nil : RemoveNodeMarkStep(p.pos, mark)
    }

    public func toJSON() -> JSON { ["stepType": "removeNodeMark", "pos": .number(Double(pos)), "mark": mark.toJSON()] }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let pos = num(json, "pos"), let m = json["mark"] else {
            throw ProseError.range("Invalid input for RemoveNodeMarkStep.fromJSON")
        }
        return RemoveNodeMarkStep(pos, try schema.markFromJSON(m))
    }
}

// MARK: - Attribute steps

public final class AttrStep: Step {
    public static let jsonID = "attr"
    public let pos: Int
    public let attr: String
    public let value: JSON

    public init(_ pos: Int, _ attr: String, _ value: JSON) { self.pos = pos; self.attr = attr; self.value = value }

    public func apply(_ doc: Node) -> StepResult {
        guard positionsValid(doc, pos), let node = doc.nodeAt(pos) else { return .fail("No node at attribute step's position") }
        var attrs = node.attrs
        attrs[attr] = value
        guard let updated = try? node.type.computeAttrs(attrs) else { return .fail("Invalid attribute value") }
        let n = Node(type: node.type, attrs: updated, content: .empty, marks: node.marks)
        return .fromReplace(doc, pos, pos + 1, Slice(Fragment(n), openStart: 0, openEnd: node.isLeaf ? 0 : 1))
    }

    public func invert(_ doc: Node) -> Step { AttrStep(pos, attr, doc.nodeAt(pos)!.attrs[attr] ?? .null) }

    public func map(_ mapping: Mappable) -> Step? {
        let p = mapping.mapResult(pos, assoc: 1)
        return p.deletedAfter ? nil : AttrStep(p.pos, attr, value)
    }

    public func toJSON() -> JSON { ["stepType": "attr", "pos": .number(Double(pos)), "attr": .string(attr), "value": value] }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let pos = num(json, "pos"), let attr = json["attr"]?.stringValue else {
            throw ProseError.range("Invalid input for AttrStep.fromJSON")
        }
        return AttrStep(pos, attr, json["value"] ?? .null)
    }
}

public final class DocAttrStep: Step {
    public static let jsonID = "docAttr"
    public let attr: String
    public let value: JSON

    public init(_ attr: String, _ value: JSON) { self.attr = attr; self.value = value }

    public func apply(_ doc: Node) -> StepResult {
        var attrs = doc.attrs
        attrs[attr] = value
        guard let updated = try? doc.type.computeAttrs(attrs) else { return .fail("Invalid attribute value") }
        return .ok(Node(type: doc.type, attrs: updated, content: doc.content, marks: doc.marks))
    }

    public func invert(_ doc: Node) -> Step { DocAttrStep(attr, doc.attrs[attr] ?? .null) }
    public func map(_ mapping: Mappable) -> Step? { self }
    public func toJSON() -> JSON { ["stepType": "docAttr", "attr": .string(attr), "value": value] }

    public static func fromJSON(_ schema: Schema, _ json: JSON) throws -> Step {
        guard let attr = json["attr"]?.stringValue else { throw ProseError.range("Invalid input for DocAttrStep.fromJSON") }
        return DocAttrStep(attr, json["value"] ?? .null)
    }
}
