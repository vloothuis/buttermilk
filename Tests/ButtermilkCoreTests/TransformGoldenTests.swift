import XCTest
@testable import ButtermilkCore

/// Replays operations recorded from the JS reference and applies them with the Swift port.
func applyOp(_ tr: Transform, _ op: JSON, _ schema: Schema) throws -> JSON {
    var info: [String: JSON] = [:]
    func i(_ k: String) -> Int { op[k]!.int }
    switch op["op"]!.string {
    case "replace": try tr.replace(i("from"), i("to"), Slice.fromJSON(schema, op["slice"]))
    case "replaceRange": try tr.replaceRange(i("from"), i("to"), Slice.fromJSON(schema, op["slice"]))
    case "replaceWith": try tr.replaceWith(i("from"), i("to"), schema.nodeFromJSON(op["node"]!))
    case "replaceRangeWith": try tr.replaceRangeWith(i("from"), i("to"), schema.nodeFromJSON(op["node"]!))
    case "delete": try tr.delete(i("from"), i("to"))
    case "deleteRange": try tr.deleteRange(i("from"), i("to"))
    case "insertText": try tr.insert(i("pos"), schema.text(op["text"]!.string))
    case "addMark": try tr.addMark(i("from"), i("to"), schema.markFromJSON(op["mark"]!))
    case "removeMark":
        if let m = op["mark"] { try tr.removeMark(i("from"), i("to"), schema.markFromJSON(m)) }
        else if let t = op["markType"] { try tr.removeMark(i("from"), i("to"), schema.marks[t.string]!) }
        else { try tr.removeMark(i("from"), i("to"), nil as Mark?) }
    case "split":
        let typesAfter = op["typesAfter"]?.arrayValue.map { $0.map { NodeTypeAttrs(schema.nodes[$0["type"]!.string]!) } }
        let ok = canSplit(tr.doc, i("pos"), depth: i("depth"), typesAfter: typesAfter)
        info["canSplit"] = .bool(ok)
        if ok { try tr.split(i("pos"), depth: i("depth"), typesAfter: typesAfter) }
    case "join":
        info["canJoin"] = .bool(canJoin(tr.doc, i("pos")))
        let p = joinPoint(tr.doc, i("pos"), dir: i("dir"))
        info["joinPoint"] = p?.json ?? .null
        if let p { try tr.join(p) }
    case "lift":
        let range = tr.doc.resolve(i("from")).blockRange(tr.doc.resolve(i("to")))
        let target = range.flatMap(liftTarget)
        info["target"] = target?.json ?? .null
        if let range, let target { try tr.lift(range, target) }
    case "wrap":
        let range = tr.doc.resolve(i("from")).blockRange(tr.doc.resolve(i("to")))
        let wrapping = range.flatMap { findWrapping($0, schema.nodes[op["type"]!.string]!) }
        info["wrapping"] = wrapping.map { .array($0.map { .string($0.type.name) }) } ?? .null
        if let range, let wrapping { try tr.wrap(range, wrapping) }
    case "setBlockType":
        try tr.setBlockType(i("from"), i("to"), schema.nodes[op["type"]!.string]!, attrs: op["attrs"]?.objectValue)
    case "setNodeMarkup":
        let node = tr.doc.nodeAt(i("pos"))
        info["nodeType"] = node.map { .string($0.type.name) } ?? .null
        if let node, !node.isText {
            try tr.setNodeMarkup(i("pos"), type: op["type"]?.stringValue.map { schema.nodes[$0]! }, attrs: op["attrs"]?.objectValue)
        }
    case "setNodeAttribute":
        let node = tr.doc.nodeAt(i("pos"))
        info["nodeType"] = node.map { .string($0.type.name) } ?? .null
        if let node, node.type.name == "heading" { try tr.setNodeAttribute(i("pos"), op["attr"]!.string, op["value"]!) }
    default: fatalError("unknown op \(op)")
    }
    return .object(info)
}

final class TransformGoldenTests: XCTestCase {
    static let fixture = loadFixture("transform")
    let schema = testSchema

    func testTransforms() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["cases"]!.array.enumerated() {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let tr = Transform(doc)
            var failed = false
            for op in c["ops"]!.array {
                total += 1
                let before = tr.steps.count
                let desc = "case \(ci) \(op["op"]!.string) \(op)"
                if ProcessInfo.processInfo.environment["TRACE"] != nil { FileHandle.standardError.write("TRACE \(ci) \(op["op"]!.string) \(tr.doc)\n".data(using: .utf8)!) }
                do {
                    let info = try applyOp(tr, op, schema)
                    if op["error"] != nil { m.check(false, "\(desc): JS threw, Swift succeeded"); failed = true; break }
                    m.equal(info, op["info"], "\(desc) info")
                    m.equal(tr.doc.toJSON(), op["doc"], "\(desc) doc")
                    m.equal(.array(tr.steps[before...].map { $0.toJSON() }), op["steps"], "\(desc) steps")
                    try tr.doc.check()
                } catch {
                    if op["error"] == nil { m.check(false, "\(desc): Swift threw \(error)"); failed = true }
                    break
                }
            }
            if failed { continue }

            for p in c["probes"]!.array {
                total += 1
                let r = tr.mapping.mapResult(p["pos"]!.int, assoc: p["assoc"]!.int)
                let got: JSON = ["pos": p["pos"]!, "assoc": p["assoc"]!, "mapped": r.pos.json, "deleted": .bool(r.deleted),
                                 "before": .bool(r.deletedBefore), "after": .bool(r.deletedAfter),
                                 "across": .bool(r.deletedAcross),
                                 "inv": tr.mapping.invert().map(r.pos, assoc: p["assoc"]!.int).json]
                m.equal(got, p, "case \(ci) mapping probe")
            }
            total += 1
            m.equal(tr.changedRange().map { [$0.from.json, $0.to.json] }, c["changedRange"], "case \(ci) changedRange")

            // Inverting all steps must restore the original document.
            total += 1
            var d = tr.doc
            for (k, step) in tr.steps.enumerated().reversed() {
                d = step.invert(tr.docs[k]).apply(d).doc ?? d
            }
            m.check(d.eq(doc), "case \(ci) inversion did not restore the document")
        }
        m.finish("transforms", total: total)
    }

    func testHelpers() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["helpers"]!.array.enumerated() {
            total += 1
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let slice = try Slice.fromJSON(schema, c["slice"])
            let step = replaceStep(doc, c["from"]!.int, c["to"]!.int, slice)
            let ip = c["insertPoint"]!
            let got: JSON = [
                "step": step?.toJSON() ?? .null,
                "insertPoint": ["type": ip["type"]!,
                                "pos": insertPoint(doc, c["from"]!.int, schema.nodes[ip["type"]!.string]!)?.json ?? .null],
                "dropPoint": dropPoint(doc, c["from"]!.int, slice)?.json ?? .null,
            ]
            m.equal(got, .object(["step": c["step"]!, "insertPoint": ip, "dropPoint": c["dropPoint"]!]), "helper case \(ci)")
        }
        m.finish("helpers", total: total)
    }

    func testSteps() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["steps"]!.array.enumerated() {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let steps = try c["steps"]!.array.map { try StepRegistry.fromJSON(schema, $0) }
            var docs: [Node] = [doc]
            for s in steps {
                total += 1
                m.equal(s.toJSON(), c["steps"]![docs.count - 1], "case \(ci) step JSON round trip")
                guard let next = s.apply(docs.last!).doc else { m.check(false, "case \(ci) step failed"); break }
                docs.append(next)
            }
            guard docs.count == steps.count + 1 else { continue }
            for (k, s) in steps.enumerated() {
                total += 1
                m.equal(s.invert(docs[k]).toJSON(), c["inverted"]![k], "case \(ci) invert \(k)")
            }
            if steps.count > 1 {
                total += 1
                m.equal(steps[0].merge(steps[1])?.toJSON(), c["merged"], "case \(ci) merge")
            }
            if let other = c["otherSteps"] {
                let mapping = Mapping()
                var d = doc
                for sj in other.array {
                    let s = try StepRegistry.fromJSON(schema, sj)
                    d = s.apply(d).doc!
                    mapping.appendMap(s.getMap())
                }
                total += 1
                m.equal(steps[0].map(mapping)?.toJSON(), c["mapped"]![0], "case \(ci) map")
            }
        }
        m.finish("steps", total: total)
    }
}
