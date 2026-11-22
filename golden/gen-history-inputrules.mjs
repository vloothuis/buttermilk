// Golden fixtures for prosemirror-history and prosemirror-inputrules, driven through a fake view.
import {writeFileSync} from "node:fs"
import {EditorState, TextSelection} from "prosemirror-state"
import {history, undo, redo, undoDepth, redoDepth, closeHistory} from "prosemirror-history"
import {inputRules, InputRule, wrappingInputRule, textblockTypeInputRule, smartQuotes, emDash, ellipsis,
        undoInputRule} from "prosemirror-inputrules"
import * as cmd from "prosemirror-commands"
import {schema, rng, randomDoc, randomValidPos} from "./lib.mjs"

const r = rng(777)
const n = schema.nodes, m = schema.marks
const lone = /\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])|(?<!\\ud[89ab][0-9a-f]{2})\\ud[c-f][0-9a-f]{2}/i

// The same rules are built in Swift.
const rules = [
  ...smartQuotes, emDash, ellipsis,
  wrappingInputRule(/^\s*>\s$/, n.blockquote),
  wrappingInputRule(/^(\d+)\.\s$/, n.ordered_list, match => ({order: +match[1]}),
                    (match, node) => node.childCount + node.attrs.order == +match[1]),
  wrappingInputRule(/^\s*([-+*])\s$/, n.bullet_list),
  textblockTypeInputRule(/^```$/, n.code_block),
  textblockTypeInputRule(/^(#{1,6})\s$/, n.heading, match => ({level: match[1].length})),
  new InputRule(/:\)$/, "🙂"),
  new InputRule(/\(c\)$/, "©", {undoable: false}),
]

const commands = {
  enter: cmd.pcBaseKeymap["Enter"], backspace: cmd.pcBaseKeymap["Backspace"], toggleStrong: cmd.toggleMark(m.strong),
  undo, redo, undoInputRule, selectAll: cmd.selectAll, deleteSelection: cmd.deleteSelection,
}
const texts = ["a", "b", " ", "\"", "'", "-", ".", ">", "#", "1", "`", ":", ")", "(c", "😀", "x"]

function fakeView(state, plugin) {
  const view = {
    state, composing: false,
    dispatch(tr) { view.state = view.state.apply(tr) },
  }
  return view
}

const cases = []
while (cases.length < 700) {
  const doc = randomDoc(r)
  const pos = randomValidPos(r, doc)
  const withRules = r.chance(0.8)
  const plugins = [history({newGroupDelay: 500})]
  const rulesPlugin = inputRules({rules})
  if (withRules) plugins.push(rulesPlugin)
  const state = EditorState.create({doc, plugins, selection: TextSelection.between(doc.resolve(pos), doc.resolve(pos))})
  const view = fakeView(state)
  const ops = []
  let time = 1000
  let failed = false
  const count = r.int(1, 12)
  for (let i = 0; i < count; i++) {
    const roll = r.next()
    let op
    time += r.chance(0.7) ? 100 : 1000
    // Make every transaction in this op use the same time, so Swift can replay it.
    const origDispatch = view.dispatch
    view.dispatch = tr => origDispatch(tr.setTime(time))
    try {
      if (roll < 0.55) {
        const text = r.pick(texts)
        op = {op: "type", text, time}
        const {from, to} = view.state.selection
        const handled = withRules && rulesPlugin.props.handleTextInput(view, from, to, text)
        if (!handled) view.dispatch(view.state.tr.insertText(text, from, to))
        op.handled = !!handled
      } else if (roll < 0.9) {
        const name = r.pick(Object.keys(commands))
        op = {op: "command", name, time}
        op.applied = commands[name](view.state, view.dispatch)
      } else if (roll < 0.95) {
        op = {op: "close", time}
        view.dispatch(closeHistory(view.state.tr))
      } else {
        op = {op: "noHistory", time}
        view.dispatch(view.state.tr.insertText("z").setMeta("addToHistory", false))
      }
    } catch (e) { failed = true; break }
    view.dispatch = origDispatch
    op.doc = view.state.doc.toJSON()
    op.selection = view.state.selection.toJSON()
    op.undoDepth = undoDepth(view.state)
    op.redoDepth = redoDepth(view.state)
    ops.push(op)
  }
  if (failed) continue
  const c = {doc: doc.toJSON(), pos, withRules, ops}
  if (!lone.test(JSON.stringify(c))) cases.push(c)
}

writeFileSync("../Tests/ButtermilkCoreTests/Fixtures/history.json", JSON.stringify({cases}))
console.log("history:", cases.length, "cases")
