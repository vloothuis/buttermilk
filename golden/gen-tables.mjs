// Golden fixtures for prosemirror-tables: table maps, fixTables, commands, cell selections,
// paste and key handling.
import {writeFileSync} from "node:fs"
import {Schema, Slice} from "prosemirror-model"
import {EditorState, TextSelection, NodeSelection} from "prosemirror-state"
import {schema as basic} from "prosemirror-schema-basic"
import {addListNodes} from "prosemirror-schema-list"
import * as t from "prosemirror-tables"
import {rng, randomInline} from "./lib.mjs"

const schema = new Schema({
  nodes: addListNodes(basic.spec.nodes, "paragraph block*", "block").append(
    t.tableNodes({tableGroup: "block", cellContent: "block+", cellAttributes: {background: {default: null}}})),
  marks: basic.spec.marks,
})
const n = schema.nodes
const r = rng(4242)
const lone = /\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])|(?<!\\ud[89ab][0-9a-f]{2})\\ud[c-f][0-9a-f]{2}/i

function para() {
  // randomInline uses the list schema's node types; rebuild them in this schema.
  const inline = randomInline(r, 2).map(node => schema.nodeFromJSON(node.toJSON()))
  return n.paragraph.create(null, inline)
}

function randomTable(malformed) {
  const rows = []
  const height = r.int(1, 4)
  const width = r.int(1, 4)
  for (let i = 0; i < height; i++) {
    const cells = []
    let count = malformed ? r.int(0, width + 1) : width
    for (let j = 0; j < count; j++) {
      const attrs = {}
      if (malformed && r.chance(0.2)) attrs.colspan = r.int(1, 3)
      if (malformed && r.chance(0.2)) attrs.rowspan = r.int(1, 3)
      if (r.chance(0.15)) attrs.colwidth = Array.from({length: attrs.colspan || 1}, () => r.pick([0, 50, 100]))
      if (r.chance(0.1)) attrs.background = "blue"
      const type = (i == 0 && r.chance(0.3)) || r.chance(0.1) ? n.table_header : n.table_cell
      const content = [para()]
      if (r.chance(0.15)) content.push(para())
      cells.push(type.create(attrs, content))
    }
    rows.push(n.table_row.create(null, cells))
  }
  return n.table.create(null, rows)
}

function randomDoc(malformed) {
  const blocks = []
  if (r.chance(0.5)) blocks.push(para())
  blocks.push(randomTable(malformed))
  if (r.chance(0.3)) blocks.push(randomTable(false))
  if (r.chance(0.5)) blocks.push(para())
  return n.doc.create(null, blocks)
}

function allCells(doc) {
  const cells = []
  doc.descendants((node, pos) => {
    if (node.type.spec.tableRole == "cell" || node.type.spec.tableRole == "header_cell") cells.push(pos)
  })
  return cells
}

function randomSelection(doc) {
  const cells = allCells(doc)
  const roll = r.next()
  if (cells.length && roll < 0.35) {
    const a = r.pick(cells)
    const $a = doc.resolve(a)
    const sameTable = cells.filter(c => t.inSameTable($a, doc.resolve(c)))
    return t.CellSelection.create(doc, a, r.pick(sameTable))
  }
  if (cells.length && roll < 0.45) {
    const pos = r.pick(cells)
    const kind = r.next()
    if (kind < 0.5) return NodeSelection.create(doc, pos)
    if (kind < 0.75) return NodeSelection.create(doc, doc.resolve(pos).before())
    return NodeSelection.create(doc, doc.resolve(pos).before(-1))
  }
  for (;;) {
    const a = r.int(0, doc.content.size)
    const b = r.chance(0.7) ? a : r.int(0, doc.content.size)
    const sel = TextSelection.between(doc.resolve(a), doc.resolve(b))
    if (sel instanceof TextSelection) return sel
  }
}

const commands = {
  addColumnBefore: t.addColumnBefore, addColumnAfter: t.addColumnAfter, deleteColumn: t.deleteColumn,
  addRowBefore: t.addRowBefore, addRowAfter: t.addRowAfter, deleteRow: t.deleteRow,
  mergeCells: t.mergeCells, splitCell: t.splitCell, setBackground: t.setCellAttr("background", "red"),
  toggleHeaderRow: t.toggleHeaderRow, toggleHeaderColumn: t.toggleHeaderColumn, toggleHeaderCell: t.toggleHeaderCell,
  toggleRow: t.toggleHeader("row"), toggleColumn: t.toggleHeader("column"),
  nextCell: t.goToNextCell(1), prevCell: t.goToNextCell(-1), deleteTable: t.deleteTable,
  deleteCellSelection: t.deleteCellSelection,
  moveRow01: t.moveTableRow({from: 0, to: 1}), moveRow10: t.moveTableRow({from: 1, to: 0}),
  moveCol01: t.moveTableColumn({from: 0, to: 1}), moveCol20: t.moveTableColumn({from: 2, to: 0}),
  // Merge, then split the merged cell again, so splitCell sees spanning cells.
  mergeSplit: (state, dispatch) => {
    let merged = null
    if (!t.mergeCells(state, tr => { merged = state.apply(tr) })) return false
    return t.splitCell(merged, dispatch && (tr => dispatch(tr, merged)))
  },
}
const keys = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Shift-ArrowLeft", "Shift-ArrowRight",
              "Shift-ArrowUp", "Shift-ArrowDown", "Backspace", "Delete"]

function fakeView(state) {
  const view = {
    state, composing: false,
    dispatch(tr) { view.state = view.state.apply(tr) },
    endOfTextblock(dir) {
      const h = view.state.selection.$head
      return dir == "left" || dir == "up" ? h.parentOffset == 0 : h.parentOffset == h.parent.content.size
    },
  }
  return view
}

function mapJSON(map) {
  return {width: map.width, height: map.height, map: map.map, problems: map.problems || null}
}

const plugin = t.tableEditing()
const cases = []
while (cases.length < 350) {
  const raw = randomDoc(r.chance(0.5))
  let c
  try {
    const maps = []
    raw.descendants(node => { if (node.type.spec.tableRole == "table") maps.push(mapJSON(t.TableMap.get(node))) })
    const fixTr = t.fixTables(EditorState.create({doc: raw}))
    const doc = fixTr ? fixTr.doc : raw
    c = {raw: raw.toJSON(), maps, fixed: fixTr ? doc.toJSON() : null, ops: []}
    for (let k = 0; k < 6; k++) {
      const sel = randomSelection(doc)
      const state = EditorState.create({doc, selection: sel, plugins: [plugin]})
      const op = {sel: sel.toJSON(), state: state.selection.toJSON()}
      try {
        const roll = r.next()
        if (roll < 0.6) {
          const name = r.pick(Object.keys(commands))
          op.command = name
          let result = null
          op.applied = commands[name](state, (tr, base) => { result = (base || state).apply(tr) })
          if (result) { op.doc = result.doc.toJSON(); op.selection = result.selection.toJSON() }
        } else if (roll < 0.8) {
          const view = fakeView(state)
          op.key = r.pick(keys)
          op.handled = plugin.props.handleKeyDown(view, new KeyboardEvent(op.key))
          op.doc = view.state.doc.toJSON(); op.selection = view.state.selection.toJSON()
        } else {
          const view = fakeView(state)
          let slice
          if (r.chance(0.6)) {
            const src = randomSelection(doc)
            slice = src.content()
          } else {
            slice = new Slice(n.paragraph.create(null, schema.text("pasted")).content, 0, 0)
          }
          op.slice = slice.toJSON()
          op.handled = plugin.props.handlePaste(view, null, slice)
          op.doc = view.state.doc.toJSON(); op.selection = view.state.selection.toJSON()
        }
        if (state.selection instanceof t.CellSelection) {
          const s = state.selection
          op.content = s.content().toJSON()
          op.isRow = s.isRowSelection(); op.isCol = s.isColSelection()
        }
      } catch (e) { continue }
      c.ops.push(op)
    }
  } catch (e) { continue }
  if (!lone.test(JSON.stringify(c))) cases.push(c)
}

writeFileSync("../Tests/ButtermilkCoreTests/Fixtures/tables.json", JSON.stringify({cases}))
console.log("tables:", cases.length, "cases")

// Minimal KeyboardEvent stand-in for prosemirror-keymap.
function KeyboardEvent(spec) {
  const parts = spec.split("-")
  const key = parts.pop()
  this.key = key
  this.shiftKey = parts.includes("Shift")
  this.altKey = this.ctrlKey = this.metaKey = false
  this.keyCode = 0
}
