import XCTest
@testable import ButtermilkCore

/// A minimal view for driving plugins in tests.
final class FakeView: EditorViewing {
    var state: EditorState
    var time: Double = 0
    init(_ state: EditorState) { self.state = state }
    func dispatch(_ tr: Transaction) {
        tr.setTime(time)
        state = try! state.apply(tr)
    }
}

final class HistoryGoldenTests: XCTestCase {
    static let fixture = loadFixture("history")
    let schema = testSchema

    lazy var rules: [InputRule] = {
        let n = schema.nodes
        return InputRules.smartQuotes + [InputRules.emDash, InputRules.ellipsis,
            InputRules.wrappingRule("^\\s*>\\s$", n["blockquote"]!),
            InputRules.wrappingRule("^(\\d+)\\.\\s$", n["ordered_list"]!,
                                    attrs: { ["order": .number(Double($0[1]!)!)] },
                                    joinPredicate: { match, node in node.childCount + node.attrs["order"]!.intValue! == Int(match[1]!)! }),
            InputRules.wrappingRule("^\\s*([-+*])\\s$", n["bullet_list"]!),
            InputRules.textblockTypeRule("^```$", n["code_block"]!),
            InputRules.textblockTypeRule("^(#{1,6})\\s$", n["heading"]!, attrs: { ["level": .number(Double($0[1]!.count))] }),
            InputRule(":\\)$", replacement: "🙂"),
            InputRule("\\(c\\)$", replacement: "©", undoable: false),
        ]
    }()

    lazy var commands: [String: Command] = [
        "enter": Commands.pcBaseKeymap["Enter"]!, "backspace": Commands.pcBaseKeymap["Backspace"]!,
        "toggleStrong": Commands.toggleMark(schema.marks["strong"]!), "undo": History.undo, "redo": History.redo,
        "undoInputRule": InputRules.undoInputRule, "selectAll": Commands.selectAll, "deleteSelection": Commands.deleteSelection,
    ]

    func testHistoryAndInputRules() throws {
        let m = Mismatches()
        var total = 0
        for (ci, c) in Self.fixture["cases"]!.array.enumerated() {
            let doc = try schema.nodeFromJSON(c["doc"]!)
            let pos = doc.resolve(c["pos"]!.int)
            let rulesPlugin = InputRules.plugin(rules)
            var plugins = [History.plugin(HistoryOptions(newGroupDelay: 500))]
            if c["withRules"]!.boolValue! { plugins.append(rulesPlugin) }
            let view = FakeView(try EditorState.create(.init(doc: doc, selection: TextSelection.between(pos, pos), plugins: plugins)))
            for (oi, op) in c["ops"]!.array.enumerated() {
                total += 1
                view.time = op["time"]!.doubleValue!
                var got: [String: JSON] = [:]
                switch op["op"]!.string {
                case "type":
                    let text = op["text"]!.string
                    let sel = view.state.selection
                    let handled = c["withRules"]!.boolValue! && rulesPlugin.props.handleTextInput!(view, sel.from, sel.to, text)
                    if !handled { view.dispatch(try view.state.tr.insertText(text, sel.from, sel.to)) }
                    got["handled"] = .bool(handled)
                case "command":
                    got["applied"] = .bool(commands[op["name"]!.string]!(view.state, view.dispatch, view))
                case "close":
                    view.dispatch(History.closeHistory(view.state.tr))
                case "noHistory":
                    view.dispatch(try view.state.tr.insertText("z").setMeta("addToHistory", false))
                default: XCTFail("unknown op")
                }
                got["doc"] = view.state.doc.toJSON()
                got["selection"] = view.state.selection.toJSON()
                got["undoDepth"] = History.undoDepth(view.state).json
                got["redoDepth"] = History.redoDepth(view.state).json
                var expected = op.objectValue!
                for k in ["op", "text", "name", "time"] { expected.removeValue(forKey: k) }
                m.equal(.object(got), .object(expected), "case \(ci) op \(oi) \(op["op"]!.string) \(op["text"] ?? op["name"] ?? "")")
            }
        }
        m.finish("history and input rules", total: total)
    }
}
