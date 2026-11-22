import ButtermilkCore
import ButtermilkMarkdown
import ButtermilkView
import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup("Buttermilk") { ContentView() }
    }
}

enum Demo {
    static let markdown = MarkdownConverter()

    static let sample = """
    # Buttermilk

    A native Markdown editor for **macOS** and **iOS**, built on a *ProseMirror-like* core.

    ## Try it

    - Type `# ` at the start of a line for a heading.
    - Type `- ` or `1. ` for a list, `> ` for a quote.
    - Use ⌘B, ⌘I and ⌘E for bold, italic and code. ⌘Z undoes.
    - [x] Task lists work too.

    > Quotes are rendered natively.

    ```swift
    let editor = ButtermilkEditor(state: $state)
    ```

    | Feature | Status |
    |:--|--:|
    | Tables | yes |
    | Links | [milkdown.dev](https://milkdown.dev) |

    ---

    Edit away.
    """

    static func state(_ text: String) -> EditorState {
        let schema = MarkdownSchema.schema
        let doc = (try? markdown.parse(text)) ?? (try! markdown.parse(""))
        return try! EditorState.create(.init(schema: schema, doc: doc, plugins: plugins(schema)))
    }

    static func plugins(_ s: Schema) -> [Plugin] {
        let n = s.nodes, m = s.marks
        let rules: [InputRule] = [
            InputRules.textblockTypeRule("^(#{1,6})\\s$", n["heading"]!, attrs: { ["level": .number(Double($0[1]!.count))] }),
            InputRules.wrappingRule("^\\s*>\\s$", n["blockquote"]!),
            InputRules.wrappingRule("^\\s*([-+*])\\s$", n["bullet_list"]!),
            InputRules.wrappingRule("^(\\d+)\\.\\s$", n["ordered_list"]!, attrs: { ["order": .number(Double($0[1]!) ?? 1)] }),
            InputRules.textblockTypeRule("^```$", n["code_block"]!),
            InputRules.ellipsis,
        ]
        let item = n["list_item"]!
        let keys: [String: Command] = [
            "Mod-z": History.undo, "Shift-Mod-z": History.redo, "Mod-y": History.redo,
            "Backspace": InputRules.undoInputRule,
            "Mod-b": Commands.toggleMark(m["strong"]!),
            "Mod-i": Commands.toggleMark(m["em"]!),
            "Mod-e": Commands.toggleMark(m["code"]!),
            "Enter": ListCommands.splitListItem(item),
            "Tab": ListCommands.sinkListItem(item),
            "Shift-Tab": ListCommands.liftListItem(item),
        ]
        return [InputRules.plugin(rules), History.plugin(), Keymap.plugin(keys),
                Tables.editing(), GapCursor.plugin()]
    }
}

struct ContentView: View {
    @State private var state = Demo.state(Demo.sample)
    @State private var showSource = true

    var body: some View {
        content
            .toolbar {
                ToolbarItemGroup {
                    Button("Undo") { run(History.undo) }.disabled(History.undoDepth(state) == 0)
                    Button("Redo") { run(History.redo) }.disabled(History.redoDepth(state) == 0)
                    Toggle("Markdown", isOn: $showSource)
                    Button("Reset") { state = Demo.state(Demo.sample) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        HSplitView {
            ButtermilkEditor(state: $state).frame(minWidth: 320)
            if showSource { source.frame(minWidth: 240) }
        }
        .frame(minWidth: 700, minHeight: 500)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                ButtermilkEditor(state: $state)
                if showSource { Divider(); source.frame(maxHeight: 220) }
            }
            .navigationTitle("Buttermilk")
            .navigationBarTitleDisplayMode(.inline)
        }
        #endif
    }

    private var source: some View {
        ScrollView {
            Text(Demo.markdown.serialize(state.doc))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func run(_ command: Command) {
        _ = command(state, { if let next = try? state.apply($0) { state = next } }, nil)
    }
}
