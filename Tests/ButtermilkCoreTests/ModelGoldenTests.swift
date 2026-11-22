import XCTest
@testable import ButtermilkCore

final class ModelGoldenTests: XCTestCase {
    static let fixture = loadFixture("model")
    let schema = testSchema

    func testSchemaMatchesReference() throws {
        let spec = Self.fixture["schema"]!
        let names = spec["nodes"]!.array.map { $0["name"]!.string }
        XCTAssertEqual(names, schema.nodeTypes.map(\.name))
        XCTAssertEqual(spec["marks"]!.array.map { $0["name"]!.string }, schema.markTypes.map(\.name))
        for n in spec["nodes"]!.array {
            let t = schema.nodes[n["name"]!.string]!
            XCTAssertEqual(n["content"]?.stringValue, t.spec.content, t.name)
            XCTAssertEqual(n["group"]?.stringValue, t.spec.group, t.name)
            XCTAssertEqual(n["defining"]?.boolValue ?? false, t.spec.defining, t.name)
            XCTAssertEqual(Set((n["attrs"]?.objectValue ?? [:]).keys), Set(t.attrs.keys), t.name)
        }
    }

    func testDocuments() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["cases"]!.array.enumerated() {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            try doc.check()
            total += 5
            m.equal(doc.toJSON(), c["doc"], "case \(ci) toJSON")
            m.check(doc.description == c["str"]!.string, "case \(ci) toString: \(doc) vs \(c["str"]!.string)")
            m.check(doc.textContent == c["textContent"]!.string, "case \(ci) textContent")
            m.check(doc.nodeSize == c["nodeSize"]!.int, "case \(ci) nodeSize")
            m.check(doc.textBetween(0, doc.content.size, blockSeparator: "\n", leafText: { _ in "*" })
                    == c["textBetween"]!.string, "case \(ci) textBetween")

            for p in c["positions"]!.array {
                total += 1
                let pos = p["pos"]!.int
                let r = doc.resolve(pos)
                var path: [JSON] = []
                for d in 0...r.depth {
                    path.append(.object([
                        "type": .string(r.node(d).type.name), "index": r.index(d).json, "indexAfter": r.indexAfter(d).json,
                        "start": r.start(d).json, "end": r.end(d).json,
                        "before": d > 0 ? r.before(d).json : .null, "after": d > 0 ? r.after(d).json : .null,
                    ]))
                }
                let nodeAt: JSON = pos < doc.content.size ? (doc.nodeAt(pos).map { .string($0.type.name) } ?? .null) : .null
                let got: JSON = .object([
                    "pos": pos.json, "depth": r.depth.json, "parentOffset": r.parentOffset.json,
                    "textOffset": r.textOffset.json, "path": .array(path), "str": .string(r.description),
                    "marks": .array(r.marks().map { .string($0.type.name) }),
                    "nodeBefore": r.nodeBefore?.toJSON() ?? .null, "nodeAfter": r.nodeAfter?.toJSON() ?? .null,
                    "nodeAt": nodeAt,
                ])
                m.equal(got, p, "case \(ci) resolve(\(pos))")
            }

            for s in c["slices"]!.array {
                total += 1
                let from = s["from"]!.int, to = s["to"]!.int
                let slice = doc.slice(from, to, includeParents: s["includeParents"]!.boolValue!)
                m.equal(.object(["slice": slice.toJSON() ?? .null, "str": .string(slice.description), "size": slice.size.json,
                                 "shared": doc.resolve(from).sharedDepth(to).json]),
                        .object(["slice": s["slice"]!, "str": s["str"]!, "size": s["size"]!, "shared": s["shared"]!]),
                        "case \(ci) slice(\(from), \(to))")
            }

            for b in c["between"]!.array {
                total += 1
                let from = b["from"]!.int, to = b["to"]!.int
                var seen: [JSON] = []
                doc.nodesBetween(from, to) { node, pos, parent, index in
                    seen.append([.string(node.type.name), pos.json, parent.map { .string($0.type.name) } ?? .null, index.json])
                    return !node.type.spec.defining
                }
                m.equal(.object(["nodes": .array(seen), "text": .string(doc.textBetween(from, to, blockSeparator: "|")),
                                 "hasEm": .bool(doc.rangeHasMark(from, to, schema.marks["em"]!))]),
                        .object(["nodes": b["nodes"]!, "text": b["text"]!, "hasEm": b["hasEm"]!]),
                        "case \(ci) nodesBetween(\(from), \(to))")
            }

            for b in c["blockRanges"]!.array {
                total += 1
                let rf = doc.resolve(b["from"]!.int), rt = doc.resolve(b["to"]!.int)
                let range = rf.blockRange(rt)
                let got: JSON = range.map {
                    .object(["depth": $0.depth.json, "start": $0.start.json, "end": $0.end.json,
                             "startIndex": $0.startIndex.json, "endIndex": $0.endIndex.json])
                } ?? .null
                let across: JSON = rf.marksAcross(rt).map { .array($0.map { .string($0.type.name) }) } ?? .null
                m.equal(.object(["range": got, "marksAcross": across]),
                        .object(["range": b["range"]!, "marksAcross": b["marksAcross"]!]), "case \(ci) blockRange")
            }

            for rp in c["replaces"]!.array {
                total += 1
                let slice = try Slice.fromJSON(schema, rp["slice"])
                do {
                    let result = try doc.replace(rp["from"]!.int, rp["to"]!.int, slice)
                    m.equal(result.toJSON(), rp["doc"], "case \(ci) replace \(rp["from"]!)-\(rp["to"]!)")
                } catch {
                    m.check(rp["error"] != nil, "case \(ci) replace threw \(error) but JS succeeded")
                }
            }

            for d in c["diffs"]!.array {
                total += 1
                let other = try schema.nodeFromJSON(d["other"]!)
                let start = doc.content.findDiffStart(other.content)
                let end = doc.content.findDiffEnd(other.content)
                m.equal(.object(["start": start?.json ?? .null, "end": end.map { [$0.a.json, $0.b.json] } ?? .null]),
                        .object(["start": d["start"]!, "end": d["end"]!]), "case \(ci) diff")
            }
        }
        m.finish("model documents", total: total)
    }

    func testContentExpressions() throws {
        let m = Mismatches()
        var total = 0
        for c in Self.fixture["content"]!.array {
            total += 1
            let expr = c["expr"]!.string
            var nodes = ListSchema.addListNodes(BasicSchema.nodes, itemContent: "paragraph block*", listGroup: "block")
            nodes[0].1.content = expr
            let s: Schema
            do { s = try Schema(nodeList: nodes, markList: BasicSchema.marks) } catch {
                m.check(c["error"]?.boolValue == true, "\(expr) failed to compile: \(error)")
                continue
            }
            if c["error"]?.boolValue == true { m.check(false, "\(expr) should fail to compile"); continue }
            let match = s.topNodeType.contentMatch
            m.check(match.description == c["dfa"]!.string, "\(expr) dfa\n\(match)\nvs\n\(c["dfa"]!.string)")
            m.check(match.inlineContent == c["inlineContent"]!.boolValue!, "\(expr) inlineContent")
            m.equal(match.defaultType.map { .string($0.name) }, c["defaultType"], "\(expr) defaultType")
            for (name, expected) in c["wrap"]!.objectValue! {
                let w = match.findWrapping(s.nodes[name]!)
                m.equal(w.map { .array($0.map { .string($0.name) }) }, expected, "\(expr) wrap \(name)")
            }
            m.equal(match.fillBefore(.empty, toEnd: true)?.toJSON(), c["fill"]!["toEnd"], "\(expr) fill")
            m.equal(s.topNodeType.createAndFill()?.toJSON(), c["createAndFill"], "\(expr) createAndFill")
        }
        m.finish("content expressions", total: total)
    }

    func testMarkSets() throws {
        let m = Mismatches()
        var total = 0
        for ops in Self.fixture["marks"]!.array {
            var set: [Mark] = []
            for op in ops.array {
                total += 1
                let mark = try schema.markFromJSON(op["mark"]!)
                set = op["add"]!.boolValue! ? mark.addToSet(set) : mark.removeFromSet(set)
                m.equal(.array(set.map { $0.toJSON() }), op["result"], "mark set")
            }
        }
        m.finish("mark sets", total: total)
    }
}
