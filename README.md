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
  - Keymap, History (undo and redo, with action names such as "Typing" for the Edit menu), InputRules, GapCursor and KillRing (Emacs-style kill and yank).
  - Search: the `prosemirror-search` query, plugin and commands (find next and previous, replace,
    replace all). Matches are inline decorations; pass `matchAttributes` to style them.
  - Outline: top-level headings as a list or tree, the section at a position with its ancestor
    headings, and commands to select a section or move to the next or previous heading.
  - Tables: the `prosemirror-tables` schema, `TableMap`, `CellSelection`, commands, paste handling
    and the table editing plugin.
- **ButtermilkView**: a native editor view.
  - `ButtermilkTextView` is an `NSTextView` on macOS and a `UITextView` on iOS. It uses TextKit, so
    system text input, spell checking, dictation and accessibility work as usual.
  - `ButtermilkEditor` wraps it for SwiftUI.
  - Decorations: inline, node and widget decorations in a `DecorationSet`, supplied by the
    `decorations` plugin prop, as in `prosemirror-view`. Widget text belongs to no position.
  - Node views: `core.nodeViews` maps a node type to a host-supplied `NodeView`. Its view
    sits over an attachment character, so it can take focus and handle its own input.
    `core.nodeViewFilter` limits which nodes get one. An `EditableNodeView` can take the cursor
    from arrow keys and hand it back.
  - Diagram blocks: `DiagramBlocks(languages:completer:linter:).install(on: core)` edits code
    blocks in a diagram language in an embedded, highlighted code editor (`DiagramEditor`), with
    host-provided completions and lint diagnostics shown as underlines.
  - Table controls: `TableControl` lists the row, column and table commands that apply to the
    selection (`core.tableControls`, `core.run(_:)`). The AppKit view adds them to the context
    menu; the UIKit view adds a Table submenu to the edit menu.
  - `DocumentRenderer` turns a document into attributed text. It knows the basic, list and table
    schemas and the node names Milkdown uses.

- **ButtermilkMarkdown**: Markdown parsing and writing with Apple's
  [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm).
  - `MarkdownSchema` covers CommonMark plus GitHub tables, strikethrough and task lists.
  - `MarkdownConverter` parses Markdown into a document and serializes a document back.
  - The output follows Milkdown's remark serializer. The differences are listed in
    [docs/markdown-round-trip.md](docs/markdown-round-trip.md).

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
selections, transactions, history, input rules, the gap cursor and tables. `gen-markdown.mjs`
runs the Markdown documents in `golden/markdown-corpus` through a headless Milkdown editor and saves
its output, so the tests can compare Markdown round trips.

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
