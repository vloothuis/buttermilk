// Generates golden fixtures for prosemirror-state, prosemirror-commands and the schema-list commands.
import {writeFileSync} from "node:fs"
import {EditorState, Selection, TextSelection, NodeSelection, AllSelection} from "prosemirror-state"
import * as cmd from "prosemirror-commands"
import {wrapInList, splitListItem, liftListItem, sinkListItem} from "prosemirror-schema-list"
import {schema, rng, randomDoc, randomValidPos, randomInline} from "./lib.mjs"

const out = "../Tests/ButtermilkCoreTests/Fixtures/"
const r = rng(4242)
const n = schema.nodes, m = schema.marks

// Commands by name. Swift uses the same names.
const commands = {
  deleteSelection: cmd.deleteSelection, joinBackward: cmd.joinBackward, joinForward: cmd.joinForward,
  joinTextblockBackward: cmd.joinTextblockBackward, joinTextblockForward: cmd.joinTextblockForward,
  selectNodeBackward: cmd.selectNodeBackward, selectNodeForward: cmd.selectNodeForward,
  joinUp: cmd.joinUp, joinDown: cmd.joinDown, lift: cmd.lift, newlineInCode: cmd.newlineInCode,
  exitCode: cmd.exitCode, createParagraphNear: cmd.createParagraphNear, liftEmptyBlock: cmd.liftEmptyBlock,
  splitBlock: cmd.splitBlock, splitBlockKeepMarks: cmd.splitBlockKeepMarks, selectParentNode: cmd.selectParentNode,
  selectAll: cmd.selectAll, selectTextblockStart: cmd.selectTextblockStart, selectTextblockEnd: cmd.selectTextblockEnd,
  wrapInBlockquote: cmd.wrapIn(n.blockquote), setHeading2: cmd.setBlockType(n.heading, {level: 2}),
  setParagraph: cmd.setBlockType(n.paragraph), setCodeBlock: cmd.setBlockType(n.code_block),
  toggleStrong: cmd.toggleMark(m.strong), toggleEm: cmd.toggleMark(m.em),
  toggleLink: cmd.toggleMark(m.link, {href: "x"}),
  toggleStrongNoRemove: cmd.toggleMark(m.strong, null, {removeWhenPresent: false}),
  toggleEmWhitespace: cmd.toggleMark(m.em, null, {includeWhitespace: true}),
  autoJoinWrapBullet: cmd.autoJoin(wrapInList(n.bullet_list), ["bullet_list"]),
  wrapBulletList: wrapInList(n.bullet_list), wrapOrderedList: wrapInList(n.ordered_list),
  splitListItem: splitListItem(n.list_item), liftListItem: liftListItem(n.list_item),
  sinkListItem: sinkListItem(n.list_item),
  backspace: cmd.pcBaseKeymap["Backspace"], del: cmd.pcBaseKeymap["Delete"], enter: cmd.pcBaseKeymap["Enter"],
}
const names = Object.keys(commands)

function randomSelection(doc) {
  const roll = r.next()
  if (roll < 0.08) return new AllSelection(doc)
  if (roll < 0.25) {
    const candidates = []
    doc.descendants((node, pos) => { if (NodeSelection.isSelectable(node)) candidates.push(pos) })
    if (candidates.length) return NodeSelection.create(doc, r.pick(candidates))
  }
  const a = randomValidPos(r, doc)
  const b = r.chance(0.5) ? a : randomValidPos(r, doc)
  return TextSelection.between(doc.resolve(a), doc.resolve(b))
}

// Swift strings cannot hold lone surrogates, so drop cases whose JSON contains one.
const lone = /\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])|(?<!\\ud[89ab][0-9a-f]{2})\\ud[c-f][0-9a-f]{2}/i
const clean = c => !lone.test(JSON.stringify(c))

function stateJSON(state) {
  return {doc: state.doc.toJSON(), selection: state.selection.toJSON(),
          storedMarks: state.storedMarks ? state.storedMarks.map(x => x.toJSON()) : null}
}

// Command cases: run one command on a random state.
const commandCases = []
while (commandCases.length < 3000) {
  const doc = randomDoc(r)
  let state = EditorState.create({doc, selection: randomSelection(doc)})
  if (r.chance(0.15)) state = state.apply(state.tr.setStoredMarks([m.em.create()]))
  const name = r.pick(names)
  let result = null
  let applies
  try {
    applies = commands[name](state)
    commands[name](state, tr => { result = stateJSON(state.apply(tr)) })
  } catch (e) { continue }
  const cc = {command: name, state: stateJSON(state), applies, result}
  if (clean(cc)) commandCases.push(cc)
}

// Selection cases.
const selectionCases = []
while (selectionCases.length < 600) {
  const doc = randomDoc(r)
  const pos = randomValidPos(r, doc), other = randomValidPos(r, doc)
  const $pos = doc.resolve(pos), $other = doc.resolve(other)
  const j = s => s ? s.toJSON() : null
  const c = {
    doc: doc.toJSON(), pos, other,
    findFromFwd: j(Selection.findFrom($pos, 1)), findFromBack: j(Selection.findFrom($pos, -1)),
    findFromText: j(Selection.findFrom($pos, 1, true)),
    near: j(Selection.near($pos)), nearBack: j(Selection.near($pos, -1)),
    atStart: j(Selection.atStart(doc)), atEnd: j(Selection.atEnd(doc)),
    between: j(TextSelection.between($pos, $other)), betweenBias: j(TextSelection.between($pos, $other, -1)),
  }
  // Map a selection through an edit, and through a bookmark.
  const sel = randomSelection(doc)
  const state = EditorState.create({doc, selection: sel})
  const tr = state.tr
  const from = randomValidPos(r, doc), to = Math.min(doc.content.size, from + r.int(0, 4))
  const kind = r.chance(0.5) ? "delete" : "insertText"
  try { kind == "delete" ? tr.delete(from, to) : tr.insertText("ab", from, to) } catch (e) { continue }
  c.sel = sel.toJSON()
  c.edit = {from, to, kind}
  c.content = sel.content().toJSON()
  c.mapped = tr.selection.toJSON()
  c.bookmark = sel.getBookmark().map(tr.mapping).resolve(tr.doc).toJSON()
  c.editedDoc = tr.doc.toJSON()
  if (clean(c)) selectionCases.push(c)
}

// Transaction cases: selection-level edits.
const trCases = []
while (trCases.length < 800) {
  const doc = randomDoc(r)
  const state = EditorState.create({doc, selection: randomSelection(doc)})
  const tr = state.tr
  const roll = r.next()
  let op
  try {
    if (roll < 0.25) { op = {op: "insertText", text: r.pick(["x", "hello", "😀", ""])}; tr.insertText(op.text) }
    else if (roll < 0.4) { op = {op: "deleteSelection"}; tr.deleteSelection() }
    else if (roll < 0.55) {
      const node = r.chance(0.5) ? schema.nodes.image.create({src: "i"}) : schema.nodes.horizontal_rule.create()
      op = {op: "replaceSelectionWith", node: node.toJSON(), inherit: r.chance(0.7)}
      tr.replaceSelectionWith(node, op.inherit)
    } else if (roll < 0.7) {
      const src = randomDoc(r), a = randomValidPos(r, src), b = randomValidPos(r, src)
      const slice = src.slice(Math.min(a, b), Math.max(a, b))
      op = {op: "replaceSelection", slice: slice.toJSON()}
      tr.replaceSelection(slice)
    } else if (roll < 0.85) {
      const from = randomValidPos(r, doc), to = r.chance(0.5) ? from : randomValidPos(r, doc)
      op = {op: "insertTextAt", text: "yo", from: Math.min(from, to), to: Math.max(from, to)}
      tr.insertText(op.text, op.from, op.to)
    } else {
      op = {op: "storedMarks"}
      tr.addStoredMark(m.strong.create()).removeStoredMark(m.em)
    }
  } catch (e) { continue }
  let after
  try { after = state.apply(tr) } catch (e) { continue }
  const tc = {state: stateJSON(state), op, result: stateJSON(after), selectionSet: tr.selectionSet,
              storedMarksSet: tr.storedMarksSet}
  if (clean(tc)) trCases.push(tc)
}

writeFileSync(out + "state.json", JSON.stringify({commands: commandCases, selections: selectionCases, transactions: trCases}))
console.log("state:", commandCases.length, "commands,", selectionCases.length, "selections,", trCases.length, "transactions")
