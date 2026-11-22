// Shared helpers for golden fixture generation.
import {Schema} from "prosemirror-model"
import {schema as basic} from "prosemirror-schema-basic"
import {addListNodes} from "prosemirror-schema-list"

export const schema = new Schema({
  nodes: addListNodes(basic.spec.nodes, "paragraph block*", "block"),
  marks: basic.spec.marks,
})

// Seeded PRNG (mulberry32) so fixtures are reproducible.
export function rng(seed) {
  let a = seed >>> 0
  const next = () => {
    a |= 0; a = a + 0x6D2B79F5 | 0
    let t = Math.imul(a ^ a >>> 15, 1 | a)
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t
    return ((t ^ t >>> 14) >>> 0) / 4294967296
  }
  return {
    next,
    int: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)),
    pick: arr => arr[Math.floor(next() * arr.length)],
    chance: p => next() < p,
  }
}

const words = ["foo", "bar", "baz", "a", "hello world", "x y", "quux", "😀", "é", "ab\ncd"]

function randomMarks(r) {
  const marks = []
  if (r.chance(0.25)) marks.push(schema.marks.em.create())
  if (r.chance(0.25)) marks.push(schema.marks.strong.create())
  if (r.chance(0.1)) marks.push(schema.marks.link.create({href: r.pick(["a", "b"])}))
  else if (r.chance(0.1)) marks.push(schema.marks.code.create())
  return marks
}

export function randomInline(r, max = 4) {
  const out = []
  const n = r.int(0, max)
  for (let i = 0; i < n; i++) {
    const roll = r.next()
    if (roll < 0.75) out.push(schema.text(r.pick(words).replace("\n", r.chance(0.5) ? "\n" : " "), randomMarks(r)))
    else if (roll < 0.88) out.push(schema.nodes.image.create({src: "img.png"}, null, randomMarks(r)))
    else out.push(schema.nodes.hard_break.create())
  }
  return out
}

export function randomBlock(r, depth = 0) {
  const roll = r.next()
  const deep = depth < 2
  if (roll < 0.4 || !deep && roll < 0.7) return schema.nodes.paragraph.create(null, randomInline(r))
  if (roll < 0.5) return schema.nodes.heading.create({level: r.int(1, 3)}, randomInline(r))
  if (roll < 0.58) return schema.nodes.code_block.create(null, r.chance(0.7) ? schema.text(r.pick(["code", "a\nb", "x"])) : null)
  if (roll < 0.63) return schema.nodes.horizontal_rule.create()
  if (roll < 0.75 && deep) return schema.nodes.blockquote.create(null, randomBlocks(r, depth + 1, 1, 2))
  const listType = r.chance(0.5) ? schema.nodes.bullet_list : schema.nodes.ordered_list
  const items = []
  for (let i = r.int(1, 3); i > 0; i--) {
    const content = [schema.nodes.paragraph.create(null, randomInline(r, 2))]
    if (deep && r.chance(0.3)) content.push(randomBlock(r, depth + 1))
    items.push(schema.nodes.list_item.create(null, content))
  }
  return listType.create(listType == schema.nodes.ordered_list && r.chance(0.3) ? {order: 3} : null, items)
}

export function randomBlocks(r, depth, min, max) {
  const out = []
  for (let i = r.int(min, max); i > 0; i--) out.push(randomBlock(r, depth))
  return out
}

export function randomDoc(r) {
  const doc = schema.nodes.doc.create(null, randomBlocks(r, 0, 1, 4))
  doc.check()
  return doc
}

// True when pos falls between the two halves of a surrogate pair. Swift strings cannot hold
// lone surrogates, so fixtures avoid such positions.
export function splitsSurrogate(doc, pos) {
  const $p = doc.resolve(pos)
  if (!$p.textOffset) return false
  const text = $p.parent.child($p.index()).text
  const c = text.charCodeAt($p.textOffset)
  return c >= 0xDC00 && c < 0xE000
}

export function randomValidPos(r, doc) {
  for (;;) { const p = r.int(0, doc.content.size); if (!splitsSurrogate(doc, p)) return p }
}

export function randomSlice(r) {
  const src = randomDoc(r)
  const a = randomValidPos(r, src), b = randomValidPos(r, src)
  return src.slice(Math.min(a, b), Math.max(a, b), r.chance(0.1))
}

export function schemaSpecJSON(schema) {
  const attrs = a => {
    if (!a) return undefined
    const out = {}
    for (const k in a) {
      const v = {}
      if ("default" in a[k]) v.default = a[k].default
      if (typeof a[k].validate == "string") v.validate = a[k].validate
      out[k] = v
    }
    return out
  }
  const nodes = [], marks = []
  schema.spec.nodes.forEach((name, spec) => {
    const s = {name}
    for (const k of ["content", "marks", "group", "inline", "atom", "selectable", "draggable", "code",
      "whitespace", "definingAsContext", "definingForContent", "defining", "isolating", "linebreakReplacement"])
      if (spec[k] !== undefined) s[k] = spec[k]
    if (spec.attrs) s.attrs = attrs(spec.attrs)
    nodes.push(s)
  })
  schema.spec.marks.forEach((name, spec) => {
    const s = {name}
    for (const k of ["inclusive", "excludes", "group", "spanning", "code"]) if (spec[k] !== undefined) s[k] = spec[k]
    if (spec.attrs) s.attrs = attrs(spec.attrs)
    marks.push(s)
  })
  return {nodes, marks, topNode: schema.spec.topNode || "doc"}
}
