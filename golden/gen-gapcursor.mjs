// Golden fixtures for prosemirror-gapcursor.
import {writeFileSync} from "node:fs"
import {EditorState, TextSelection} from "prosemirror-state"
import {GapCursor, gapCursor} from "prosemirror-gapcursor"
import {schema, rng, randomDoc} from "./lib.mjs"

const r = rng(99)
const n = schema.nodes
const lone = /\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])|(?<!\\ud[89ab][0-9a-f]{2})\\ud[c-f][0-9a-f]{2}/i
const plugin = gapCursor()
const keys = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]

// Documents with more block atoms, so gap positions are common.
function gappyDoc() {
  const doc = randomDoc(r)
  const blocks = []
  doc.forEach(b => {
    if (r.chance(0.5)) blocks.push(n.horizontal_rule.create())
    blocks.push(b)
  })
  if (r.chance(0.5)) blocks.push(n.horizontal_rule.create())
  return n.doc.create(null, blocks)
}

const cases = []
while (cases.length < 400) {
  const doc = gappyDoc()
  const c = {doc: doc.toJSON(), valid: [], fwd: [], back: [], fwdMust: [], keys: [], typed: []}
  for (let p = 0; p <= doc.content.size; p++) {
    const $p = doc.resolve(p)
    c.valid.push(GapCursor.valid($p) ? 1 : 0)
    const f = GapCursor.findFrom($p, 1), b = GapCursor.findFrom($p, -1), fm = GapCursor.findFrom($p, 1, true)
    c.fwd.push(f ? f.pos : null); c.back.push(b ? b.pos : null); c.fwdMust.push(fm ? fm.pos : null)
  }
  // Arrow keys from a random selection, with a fake view whose endOfTextblock uses offsets.
  for (let k = 0; k < 6; k++) {
    const p = r.int(0, doc.content.size)
    const $p = doc.resolve(p)
    const sel = GapCursor.valid($p) && r.chance(0.5) ? new GapCursor($p) : TextSelection.between($p, $p)
    let state = EditorState.create({doc, selection: sel, plugins: [plugin]})
    const key = r.pick(keys)
    const view = {
      state,
      dispatch(tr) { view.state = view.state.apply(tr) },
      endOfTextblock(dir) {
        const $h = view.state.selection.$head
        return dir == "left" || dir == "up" ? $h.parentOffset == 0 : $h.parentOffset == $h.parent.content.size
      },
    }
    const handled = plugin.props.handleKeyDown(view, {key, keyCode: 0, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false})
    c.keys.push({sel: sel.toJSON(), key, handled, result: view.state.selection.toJSON()})
    if (view.state.selection instanceof GapCursor) {
      const tr = view.state.tr.insertText("q")
      c.typed.push({sel: view.state.selection.toJSON(), doc: tr.doc.toJSON(), selection: tr.selection.toJSON()})
    }
  }
  if (!lone.test(JSON.stringify(c))) cases.push(c)
}
writeFileSync("../Tests/ButtermilkCoreTests/Fixtures/gapcursor.json", JSON.stringify({cases}))
console.log("gapcursor:", cases.length)
