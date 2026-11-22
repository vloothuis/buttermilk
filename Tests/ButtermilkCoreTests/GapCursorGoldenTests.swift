import XCTest
@testable import ButtermilkCore

/// A view whose `endOfTextblock` uses offsets, like the generator's fake view.
final class OffsetView: EditorViewing {
    var state: EditorState
    init(_ state: EditorState) { self.state = state }
    func dispatch(_ tr: Transaction) { state = try! state.apply(tr) }
    func endOfTextblock(_ dir: TextDirection, _ state: EditorState) -> Bool? {
        let h = self.state.selection.resolvedHead
        return dir == .left || dir == .up ? h.parentOffset == 0 : h.parentOffset == h.parent.content.size
    }
}

final class GapCursorGoldenTests: XCTestCase {
    static let fixture = loadFixture("gapcursor")
    let schema = testSchema

    func testGapCursor() throws {
        GapCursor.registerJSON()
        let plugin = GapCursor.plugin()
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["cases"]!.array.enumerated() {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            var valid: [JSON] = [], fwd: [JSON] = [], back: [JSON] = [], fwdMust: [JSON] = []
            for p in 0...doc.content.size {
                let rp = doc.resolve(p)
                valid.append(GapCursor.valid(rp) ? 1 : 0)
                fwd.append(GapCursor.findFrom(rp, 1)?.pos.json ?? .null)
                back.append(GapCursor.findFrom(rp, -1)?.pos.json ?? .null)
                fwdMust.append(GapCursor.findFrom(rp, 1, mustMove: true)?.pos.json ?? .null)
            }
            total += 1
            m.equal(["valid": .array(valid), "fwd": .array(fwd), "back": .array(back), "fwdMust": .array(fwdMust)],
                    ["valid": c["valid"]!, "fwd": c["fwd"]!, "back": c["back"]!, "fwdMust": c["fwdMust"]!], "case \(ci) positions")
            for k in c["keys"]!.array {
                total += 1
                let sel = try Selection.fromJSON(doc, k["sel"]!)
                let view = OffsetView(try EditorState.create(.init(doc: doc, selection: sel, plugins: [plugin])))
                let handled = plugin.props.handleKeyDown!(view, KeyPress(k["key"]!.string))
                m.equal(["handled": .bool(handled), "result": view.state.selection.toJSON()],
                        ["handled": k["handled"]!, "result": k["result"]!], "case \(ci) key \(k["key"]!) from \(k["sel"]!)")
            }
            for t in c["typed"]!.array {
                total += 1
                let sel = try Selection.fromJSON(doc, t["sel"]!)
                let tr = try EditorState.create(.init(doc: doc, selection: sel)).tr
                try tr.insertText("q")
                m.equal(["doc": tr.doc.toJSON(), "selection": tr.selection.toJSON()],
                        ["doc": t["doc"]!, "selection": t["selection"]!], "case \(ci) typing at \(t["sel"]!)")
            }
        }
        m.finish("gap cursor", total: total)
    }
}
