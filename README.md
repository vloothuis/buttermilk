# Buttermilk

Buttermilk is a Swift port of the editing core behind [Milkdown](https://milkdown.dev), for macOS and iOS.
Milkdown is built on [ProseMirror](https://prosemirror.net). Buttermilk ports the parts of ProseMirror
that Milkdown uses and adds a native TextKit view. It does not use a web view.

## Modules

- **ButtermilkCore**: the document model, transforms, editor state and plugins. It has no UI code.
  - Model: schemas, nodes, marks, fragments, slices, resolved positions and content expressions.
  - Transform: steps, step maps, mapping, `replace`, `lift`, `wrap`, `join`, marks and more.
  - State: `EditorState`, `Transaction`, selections (text, node, all), plugins and plugin keys.
  - Commands: the `prosemirror-commands` set, list commands and `baseKeymap`.
  - Keymap, History (undo and redo), InputRules and GapCursor.
  - Tables: the `prosemirror-tables` schema, `TableMap`, `CellSelection`, commands, paste handling
    and the table editing plugin.
- **ButtermilkView**: a native editor view.
  - `ButtermilkTextView` is an `NSTextView` on macOS and a `UITextView` on iOS. It uses TextKit, so
    system text input, spell checking, dictation and accessibility work as usual.
  - `ButtermilkEditor` wraps it for SwiftUI.
  - `DocumentRenderer` turns a document into attributed text. It knows the basic, list and table
    schemas and the node names Milkdown uses.

- **ButtermilkMarkdown**: Markdown parsing and writing with Apple's
  [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm).
  - `MarkdownSchema` covers CommonMark plus GitHub tables, strikethrough and task lists.
  - `MarkdownConverter` parses Markdown into a document and serializes a document back.
  - Nested ordered lists are always written starting at 1, because of a formatter limit.

## Usage

```swift
import ButtermilkCore
import ButtermilkMarkdown
import ButtermilkView

let markdown = MarkdownConverter()
let schema = markdown.schema
let state = try EditorState.create(.init(doc: try markdown.parse("# Hello"), plugins: [
    History.plugin(),
    Keymap.plugin(["Mod-z": History.undo, "Shift-Mod-z": History.redo]),
    Keymap.plugin(["Mod-b": Commands.toggleMark(schema.marks["strong"]!)]),
]))

// SwiftUI
struct ContentView: View {
    @State var state: EditorState
    var body: some View { ButtermilkEditor(state: $state) }
}
```

`markdown.serialize(state.doc)` turns the document back into Markdown.

The view re-renders only the top-level blocks a transaction changed. Typing in a document of
20,000 blocks takes about 4 ms per key in a release build.

A command has the type `(EditorState, ((Transaction) -> Void)?, EditorViewing?) -> Bool`, as in
ProseMirror. Positions count UTF-16 code units, so they match ProseMirror positions for the same
document.

## How it is tested

The tests compare Buttermilk with the JavaScript packages. Scripts in `golden/` run seeded random
operations against ProseMirror and save the results as JSON fixtures. The Swift tests replay the
same operations and compare the results. The fixtures cover the model, transforms, commands,
selections, transactions, history, input rules, the gap cursor and tables.

To regenerate the fixtures:

```sh
cd golden && npm install
for f in gen-*.mjs; do node "$f"; done
```

Then run the tests:

```sh
swift test
```

## Licence

MIT. Buttermilk is a port of ProseMirror (© Marijn Haverbeke and others) and follows the design of
Milkdown (© Mirone). Both are MIT licensed. See [LICENSE](LICENSE).
