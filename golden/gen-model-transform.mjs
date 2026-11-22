// Generates golden fixtures for the model and transform layers from the reference JS implementation.
import {writeFileSync} from "fs"
import {Fragment, Slice} from "prosemirror-model"
import {Transform, liftTarget, findWrapping, canSplit, canJoin, joinPoint, insertPoint, dropPoint,
  replaceStep, Step} from "prosemirror-transform"
import {schema, rng, randomDoc, randomSlice, randomInline, schemaSpecJSON, splitsSurrogate, randomValidPos} from "./lib.mjs"

const out = process.argv[2] || "../Tests/ButtermilkCoreTests/Fixtures"
const r = rng(20261122)

// ---------- Model ----------
function posInfo(doc, pos) {
  const $p = doc.resolve(pos)
  const path = []
  for (let d = 0; d <= $p.depth; d++)
    path.push({type: $p.node(d).type.name, index: $p.index(d), indexAfter: $p.indexAfter(d),
      start: $p.start(d), end: $p.end(d), before: d ? $p.before(d) : null, after: d ? $p.after(d) : null})
  return {
    pos, depth: $p.depth, parentOffset: $p.parentOffset, textOffset: $p.textOffset, path,
    str: $p.toString(),
    marks: $p.marks().map(m => m.type.name),
    nodeBefore: $p.nodeBefore ? $p.nodeBefore.toJSON() : null,
    nodeAfter: $p.nodeAfter ? $p.nodeAfter.toJSON() : null,
    nodeAt: doc.nodeAt(pos) && pos < doc.content.size ? doc.nodeAt(pos).type.name : null,
  }
}

const modelCases = []
for (let i = 0; i < 60; i++) {
  const doc = randomDoc(r)
  const size = doc.content.size
  const c = {
    doc: doc.toJSON(), str: doc.toString(), textContent: doc.textContent, nodeSize: doc.nodeSize,
    textBetween: doc.textBetween(0, size, "\n", "*"),
    positions: [], slices: [], between: [], replaces: [], blockRanges: [], diffs: [],
  }
  for (let p = 0; p <= size; p++) if (!splitsSurrogate(doc, p)) c.positions.push(posInfo(doc, p))
  for (let k = 0; k < 6; k++) {
    let a = randomValidPos(r, doc), b = randomValidPos(r, doc); if (a > b) [a, b] = [b, a]
    const inc = r.chance(0.3)
    const s = doc.slice(a, b, inc)
    c.slices.push({from: a, to: b, includeParents: inc, slice: s.toJSON(), str: s.toString(), size: s.size,
      shared: doc.resolve(a).sharedDepth(b)})
    const seen = []
    doc.nodesBetween(a, b, (node, pos, parent, index) => {
      seen.push([node.type.name, pos, parent ? parent.type.name : null, index])
      return !node.type.spec.defining
    })
    c.between.push({from: a, to: b, nodes: seen, text: doc.textBetween(a, b, "|"),
      hasEm: doc.rangeHasMark(a, b, schema.marks.em)})
    const $a = doc.resolve(a), $b = doc.resolve(b)
    const range = $a.blockRange($b)
    c.blockRanges.push({from: a, to: b, range: range ? {depth: range.depth, start: range.start, end: range.end,
      startIndex: range.startIndex, endIndex: range.endIndex} : null,
      marksAcross: $a.marksAcross($b)?.map(m => m.type.name) ?? null})
  }
  for (let k = 0; k < 6; k++) {
    let a = randomValidPos(r, doc), b = randomValidPos(r, doc); if (a > b) [a, b] = [b, a]
    const slice = randomSlice(r)
    let res
    try { res = {doc: doc.replace(a, b, slice).toJSON()} } catch (e) { res = {error: e.constructor.name} }
    c.replaces.push({from: a, to: b, slice: slice.toJSON(), ...res})
  }
  // Diffs against a lightly modified copy.
  const tr = new Transform(doc)
  const p = randomValidPos(r, doc)
  try { tr.insert(p, schema.text("Z")) } catch (e) {}
  const other = tr.doc
  const end = doc.content.findDiffEnd(other.content)
  c.diffs.push({other: other.toJSON(), start: doc.content.findDiffStart(other.content), end: end ? [end.a, end.b] : null})
  modelCases.push(c)
}

// Content expressions, compiled to DFA strings and wrapping/fill queries.
const contentExprs = ["block+", "paragraph block*", "inline*", "text*", "list_item+", "(paragraph | heading)+ horizontal_rule?",
  "heading paragraph{2,3} blockquote*", "paragraph{2,}", "(paragraph image*)*", "(heading | paragraph)? blockquote"]
const contentCases = []
for (const expr of contentExprs) {
  let s, err = null
  try {
    s = new (schema.constructor)({nodes: schema.spec.nodes.update("doc", {content: expr}), marks: schema.spec.marks})
  } catch (e) { err = e.message }
  if (err) { contentCases.push({expr, error: true}); continue }
  const m = s.topNodeType.contentMatch
  const wrap = {}, fill = {}
  for (const name of ["paragraph", "list_item", "text", "heading", "blockquote", "image"])
    wrap[name] = m.findWrapping(s.nodes[name])?.map(t => t.name) ?? null
  const filled = m.fillBefore(Fragment.empty, true)
  fill.toEnd = filled ? filled.toJSON() : null
  const created = s.topNodeType.createAndFill()
  contentCases.push({expr, dfa: m.toString(), inlineContent: m.inlineContent, defaultType: m.defaultType?.name ?? null,
    wrap, fill, createAndFill: created ? created.toJSON() : null})
}
const badExprs = ["paragraph (", "nope+", "paragraph | text", "image", "heading{x}"]
for (const expr of badExprs) {
  let ok = true
  try { new (schema.constructor)({nodes: schema.spec.nodes.update("doc", {content: expr}), marks: schema.spec.marks}) }
  catch (e) { ok = false }
  contentCases.push({expr, error: !ok})
}

// Mark set behaviour.
const markCases = []
for (let i = 0; i < 40; i++) {
  const all = [schema.marks.em.create(), schema.marks.strong.create(), schema.marks.code.create(),
    schema.marks.link.create({href: "a"}), schema.marks.link.create({href: "b"})]
  let set = []
  const ops = []
  for (let k = 0; k < 4; k++) {
    const m = r.pick(all), add = r.chance(0.7)
    set = add ? m.addToSet(set) : m.removeFromSet(set)
    ops.push({add, mark: m.toJSON(), result: set.map(x => x.toJSON())})
  }
  markCases.push(ops)
}

writeFileSync(`${out}/model.json`, JSON.stringify({schema: schemaSpecJSON(schema), cases: modelCases, content: contentCases, marks: markCases}))

// ---------- Transform ----------
function randomPos(doc) { return randomValidPos(r, doc) }
function randomRange(doc) {
  let a = randomPos(doc), b = randomPos(doc)
  if (a > b) [a, b] = [b, a]
  return [a, b]
}
const markChoices = () => r.pick([
  {mark: schema.marks.em.create().toJSON()}, {mark: schema.marks.strong.create().toJSON()},
  {mark: schema.marks.link.create({href: "a"}).toJSON()}, {mark: schema.marks.code.create().toJSON()},
])

function genOp(doc) {
  const kind = r.pick(["replace", "replace", "replaceWith", "delete", "insertText", "replaceRange", "replaceRange",
    "replaceRangeWith", "deleteRange", "deleteRange", "addMark", "removeMark", "split", "join", "lift", "wrap",
    "setBlockType", "setNodeMarkup", "setNodeAttribute"])
  const [from, to] = randomRange(doc)
  switch (kind) {
    case "replace": case "replaceRange": return {op: kind, from, to, slice: randomSlice(r).toJSON()}
    case "replaceWith": return {op: kind, from, to, node: r.pick([schema.text("Q"), schema.nodes.image.create({src: "s"}),
      schema.nodes.paragraph.create(null, schema.text("P")), schema.nodes.horizontal_rule.create()]).toJSON()}
    case "replaceRangeWith": return {op: kind, from, to, node: r.pick([schema.nodes.horizontal_rule.create(),
      schema.nodes.paragraph.create(null, schema.text("P")), schema.nodes.image.create({src: "s"}),
      schema.nodes.heading.create({level: 2}, schema.text("H"))]).toJSON()}
    case "delete": case "deleteRange": return {op: kind, from, to}
    case "insertText": return {op: kind, pos: from, text: r.pick(["x", "yz", "😀"])}
    case "addMark": return {op: kind, from, to, ...markChoices()}
    case "removeMark": {
      const c = r.next()
      if (c < 0.4) return {op: kind, from, to, ...markChoices()}
      if (c < 0.8) return {op: kind, from, to, markType: r.pick(["em", "strong", "link", "code"])}
      return {op: kind, from, to}
    }
    case "split": {
      const depth = r.int(1, 3)
      const typesAfter = r.chance(0.3) ? [{type: r.pick(["paragraph", "heading"])}] : undefined
      return {op: kind, pos: from, depth, typesAfter}
    }
    case "join": return {op: kind, pos: from, dir: r.chance(0.5) ? -1 : 1}
    case "lift": return {op: kind, from, to}
    case "wrap": return {op: kind, from, to, type: r.pick(["blockquote", "bullet_list", "ordered_list", "list_item"])}
    case "setBlockType": return {op: kind, from, to, type: r.pick(["paragraph", "heading", "code_block"]),
      attrs: r.chance(0.5) ? {level: r.int(1, 3)} : null}
    case "setNodeMarkup": return {op: kind, pos: from, type: r.pick([null, "paragraph", "heading", "blockquote"]),
      attrs: r.chance(0.5) ? {level: 2} : null}
    case "setNodeAttribute": return {op: kind, pos: from, attr: "level", value: r.int(1, 6)}
  }
}

// Applies an op, returning extra info computed by helpers. Throws on failure.
function applyOp(tr, op) {
  const info = {}
  switch (op.op) {
    case "replace": tr.replace(op.from, op.to, Slice.fromJSON(schema, op.slice)); break
    case "replaceRange": tr.replaceRange(op.from, op.to, Slice.fromJSON(schema, op.slice)); break
    case "replaceWith": tr.replaceWith(op.from, op.to, schema.nodeFromJSON(op.node)); break
    case "replaceRangeWith": tr.replaceRangeWith(op.from, op.to, schema.nodeFromJSON(op.node)); break
    case "delete": tr.delete(op.from, op.to); break
    case "deleteRange": tr.deleteRange(op.from, op.to); break
    case "insertText": tr.insert(op.pos, schema.text(op.text)); break
    case "addMark": tr.addMark(op.from, op.to, schema.markFromJSON(op.mark)); break
    case "removeMark":
      tr.removeMark(op.from, op.to, op.mark ? schema.markFromJSON(op.mark) : op.markType ? schema.marks[op.markType] : null); break
    case "split": {
      const typesAfter = op.typesAfter?.map(t => ({type: schema.nodes[t.type]}))
      info.canSplit = canSplit(tr.doc, op.pos, op.depth, typesAfter)
      if (info.canSplit) tr.split(op.pos, op.depth, typesAfter)
      break
    }
    case "join": {
      info.canJoin = canJoin(tr.doc, op.pos)
      info.joinPoint = joinPoint(tr.doc, op.pos, op.dir) ?? null
      if (info.joinPoint != null) tr.join(info.joinPoint)
      break
    }
    case "lift": {
      const range = tr.doc.resolve(op.from).blockRange(tr.doc.resolve(op.to))
      info.target = range ? liftTarget(range) ?? null : null
      if (info.target != null) tr.lift(range, info.target)
      break
    }
    case "wrap": {
      const range = tr.doc.resolve(op.from).blockRange(tr.doc.resolve(op.to))
      const wrapping = range && findWrapping(range, schema.nodes[op.type])
      info.wrapping = wrapping ? wrapping.map(w => w.type.name) : null
      if (wrapping) tr.wrap(range, wrapping)
      break
    }
    case "setBlockType": tr.setBlockType(op.from, op.to, schema.nodes[op.type], op.attrs); break
    case "setNodeMarkup": {
      const node = tr.doc.nodeAt(op.pos)
      info.nodeType = node ? node.type.name : null
      if (node && !node.isText) tr.setNodeMarkup(op.pos, op.type ? schema.nodes[op.type] : null, op.attrs)
      break
    }
    case "setNodeAttribute": {
      const node = tr.doc.nodeAt(op.pos)
      info.nodeType = node ? node.type.name : null
      if (node && node.type.name == "heading") tr.setNodeAttribute(op.pos, op.attr, op.value)
      break
    }
  }
  return info
}

const transformCases = []
let tries = 0
while (transformCases.length < 1500 && tries++ < 20000) {
  const doc = randomDoc(r)
  const tr = new Transform(doc)
  const ops = []
  for (let k = r.int(1, 3); k > 0; k--) {
    const op = genOp(tr.doc)
    const stepsBefore = tr.steps.length
    let info, error = null
    try { info = applyOp(tr, op) } catch (e) {
      if (e.name != "TransformError") { ops.length = 0; break }
      error = e.message
    }
    if (error) { ops.push({...op, error: true}); break }
    try { tr.doc.check() } catch (e) { ops.length = 0; break }
    ops.push({...op, info, doc: tr.doc.toJSON(), steps: tr.steps.slice(stepsBefore).map(s => s.toJSON())})
  }
  if (!ops.length) continue
  // Mapping probes and inversion.
  const probes = []
  for (let k = 0; k < 8; k++) {
    const pos = randomPos(doc), assoc = r.chance(0.5) ? 1 : -1
    const res = tr.mapping.mapResult(pos, assoc)
    probes.push({pos, assoc, mapped: res.pos, deleted: res.deleted, before: res.deletedBefore, after: res.deletedAfter,
      across: res.deletedAcross, inv: tr.mapping.invert().map(res.pos, assoc)})
  }
  const changed = tr.changedRange()
  transformCases.push({doc: doc.toJSON(), ops, probes, changedRange: changed ? [changed.from, changed.to] : null})
}

// replaceStep / insertPoint / dropPoint helpers.
const helperCases = []
for (let i = 0; i < 300; i++) {
  const doc = randomDoc(r)
  const [from, to] = randomRange(doc)
  const slice = randomSlice(r)
  const step = replaceStep(doc, from, to, slice)
  const nodeType = r.pick(["horizontal_rule", "paragraph", "image", "heading", "list_item"])
  helperCases.push({doc: doc.toJSON(), from, to, slice: slice.toJSON(), step: step ? step.toJSON() : null,
    insertPoint: {type: nodeType, pos: insertPoint(doc, from, schema.nodes[nodeType]) ?? null},
    dropPoint: dropPoint(doc, from, slice) ?? null})
}

// Step merge/map/invert behaviour on transform output.
const stepCases = []
for (const c of transformCases.slice(0, 400)) {
  const doc = schema.nodeFromJSON(c.doc)
  const tr = new Transform(doc)
  try { for (const op of c.ops) if (!op.error) applyOp(tr, op) } catch (e) { continue }
  if (tr.steps.length < 1) continue
  const s = tr.steps
  const entry = {doc: c.doc, steps: s.map(x => x.toJSON()), inverted: [], merged: null, mapped: []}
  for (let i = 0; i < s.length; i++) entry.inverted.push(s[i].invert(tr.docs[i]).toJSON())
  if (s.length > 1) { const m = s[0].merge(s[1]); entry.merged = m ? m.toJSON() : null }
  const other = randomOther(doc)
  if (other) {
    for (const st of s.slice(0, 1)) { const mapped = st.map(other.mapping); entry.mapped.push(mapped ? mapped.toJSON() : null) }
    entry.otherSteps = other.steps.map(x => x.toJSON())
  }
  stepCases.push(entry)
}
function randomOther(doc) {
  const tr = new Transform(doc)
  try { tr.insert(randomPos(doc), schema.text("M")) } catch (e) {}
  try { const [a, b] = randomRange(tr.doc); tr.delete(a, b) } catch (e) {}
  return tr.steps.length ? tr : null
}

writeFileSync(`${out}/transform.json`, JSON.stringify({cases: transformCases, helpers: helperCases, steps: stepCases}))
console.log(`model: ${modelCases.length}, transform: ${transformCases.length}, helpers: ${helperCases.length}, steps: ${stepCases.length}`)
