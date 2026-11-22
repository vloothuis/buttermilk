import XCTest
@testable import ButtermilkCore

final class StateGoldenTests: XCTestCase {
    static let fixture = loadFixture("state")
    let schema = testSchema

    lazy var commands: [String: Command] = {
        let n = schema.nodes, m = schema.marks
        let keymap = Commands.pcBaseKeymap
        return [
            "deleteSelection": Commands.deleteSelection, "joinBackward": Commands.joinBackward,
            "joinForward": Commands.joinForward, "joinTextblockBackward": Commands.joinTextblockBackward,
            "joinTextblockForward": Commands.joinTextblockForward, "selectNodeBackward": Commands.selectNodeBackward,
            "selectNodeForward": Commands.selectNodeForward, "joinUp": Commands.joinUp, "joinDown": Commands.joinDown,
            "lift": Commands.lift, "newlineInCode": Commands.newlineInCode, "exitCode": Commands.exitCode,
            "createParagraphNear": Commands.createParagraphNear, "liftEmptyBlock": Commands.liftEmptyBlock,
            "splitBlock": Commands.splitBlock, "splitBlockKeepMarks": Commands.splitBlockKeepMarks,
            "selectParentNode": Commands.selectParentNode, "selectAll": Commands.selectAll,
            "selectTextblockStart": Commands.selectTextblockStart, "selectTextblockEnd": Commands.selectTextblockEnd,
            "wrapInBlockquote": Commands.wrapIn(n["blockquote"]!),
            "setHeading2": Commands.setBlockType(n["heading"]!, attrs: ["level": 2]),
            "setParagraph": Commands.setBlockType(n["paragraph"]!), "setCodeBlock": Commands.setBlockType(n["code_block"]!),
            "toggleStrong": Commands.toggleMark(m["strong"]!), "toggleEm": Commands.toggleMark(m["em"]!),
            "toggleLink": Commands.toggleMark(m["link"]!, attrs: ["href": "x"]),
            "toggleStrongNoRemove": Commands.toggleMark(m["strong"]!, options: .init(removeWhenPresent: false)),
            "toggleEmWhitespace": Commands.toggleMark(m["em"]!, options: .init(includeWhitespace: true)),
            "autoJoinWrapBullet": Commands.autoJoin(ListCommands.wrapInList(n["bullet_list"]!), ["bullet_list"]),
            "wrapBulletList": ListCommands.wrapInList(n["bullet_list"]!),
            "wrapOrderedList": ListCommands.wrapInList(n["ordered_list"]!),
            "splitListItem": ListCommands.splitListItem(n["list_item"]!),
            "liftListItem": ListCommands.liftListItem(n["list_item"]!),
            "sinkListItem": ListCommands.sinkListItem(n["list_item"]!),
            "backspace": keymap["Backspace"]!, "del": keymap["Delete"]!, "enter": keymap["Enter"]!,
        ]
    }()

    func makeState(_ j: JSON) throws -> EditorState {
        let doc = try schema.nodeFromJSON(j["doc"]!)
        let sel = try Selection.fromJSON(doc, j["selection"]!)
        let marks = try j["storedMarks"]?.arrayValue.map { try $0.map(schema.markFromJSON) }
        return try EditorState.create(.init(doc: doc, selection: sel, storedMarks: marks))
    }

    func stateJSON(_ s: EditorState) -> JSON {
        ["doc": s.doc.toJSON(), "selection": s.selection.toJSON(),
         "storedMarks": s.storedMarks.map { .array($0.map { $0.toJSON() }) } ?? .null]
    }

    func testCommands() throws {
        let m = Mismatches()
        var total = 0
        var perCommand: [String: Int] = [:]
        for (ci, c) in Self.fixture["commands"]!.array.enumerated() {
            total += 1
            let name = c["command"]!.string
            let state = try makeState(c["state"]!)
            let command = commands[name]!
            let applies = command(state, nil, nil)
            var result: JSON = .null
            _ = command(state, { tr in result = (try? self.stateJSON(state.apply(tr))) ?? "apply failed" }, nil)
            let ok = applies == c["applies"]!.boolValue! && normalize(result) == normalize(c["result"])
            if !ok { perCommand[name, default: 0] += 1 }
            m.equal(["applies": .bool(applies), "result": result], ["applies": c["applies"]!, "result": c["result"] ?? .null],
                    "case \(ci) \(name) on \(c["state"]!)")
        }
        if !perCommand.isEmpty { print("failing commands: \(perCommand)") }
        m.finish("commands", total: total)
    }

    func testSelections() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["selections"]!.array.enumerated() {
            total += 1
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let pos = doc.resolve(c["pos"]!.int), other = doc.resolve(c["other"]!.int)
            var got: [String: JSON] = [
                "findFromFwd": Selection.findFrom(pos, 1)?.toJSON() ?? .null,
                "findFromBack": Selection.findFrom(pos, -1)?.toJSON() ?? .null,
                "findFromText": Selection.findFrom(pos, 1, textOnly: true)?.toJSON() ?? .null,
                "near": Selection.near(pos).toJSON(), "nearBack": Selection.near(pos, bias: -1).toJSON(),
                "atStart": Selection.atStart(doc).toJSON(), "atEnd": Selection.atEnd(doc).toJSON(),
                "between": TextSelection.between(pos, other).toJSON(),
                "betweenBias": TextSelection.between(pos, other, bias: -1).toJSON(),
            ]
            let sel = try Selection.fromJSON(doc, c["sel"]!)
            let state = try EditorState.create(.init(doc: doc, selection: sel))
            let tr = state.tr
            let from = c["edit"]!["from"]!.int, to = c["edit"]!["to"]!.int
            if c["edit"]!["kind"]!.string == "delete" { try tr.delete(from, to) } else { try tr.insertText("ab", from, to) }
            got["content"] = sel.content().toJSON() ?? .null
            got["mapped"] = tr.selection.toJSON()
            got["bookmark"] = sel.getBookmark().map(tr.mapping).resolve(tr.doc).toJSON()
            got["editedDoc"] = tr.doc.toJSON()
            var expected = c.objectValue!
            for k in ["doc", "pos", "other", "sel", "edit"] { expected.removeValue(forKey: k) }
            m.equal(.object(got), .object(expected), "selection case \(ci)")
        }
        m.finish("selections", total: total)
    }

    func testTransactions() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["transactions"]!.array.enumerated() {
            total += 1
            let state = try makeState(c["state"]!)
            let tr = state.tr
            let op = c["op"]!
            switch op["op"]!.string {
            case "insertText": try tr.insertText(op["text"]!.string)
            case "deleteSelection": try tr.deleteSelection()
            case "replaceSelectionWith": try tr.replaceSelectionWith(schema.nodeFromJSON(op["node"]!), inheritMarks: op["inherit"]!.boolValue!)
            case "replaceSelection": try tr.replaceSelection(Slice.fromJSON(schema, op["slice"]))
            case "insertTextAt": try tr.insertText(op["text"]!.string, op["from"]!.int, op["to"]!.int)
            case "storedMarks": tr.addStoredMark(schema.marks["strong"]!.create()).removeStoredMark(schema.marks["em"]!)
            default: XCTFail("unknown op")
            }
            let after = try state.apply(tr)
            m.equal(["result": stateJSON(after), "selectionSet": .bool(tr.selectionSet), "storedMarksSet": .bool(tr.storedMarksSet)],
                    ["result": c["result"]!, "selectionSet": c["selectionSet"]!, "storedMarksSet": c["storedMarksSet"]!],
                    "transaction case \(ci) \(op)")
        }
        m.finish("transactions", total: total)
    }
}
