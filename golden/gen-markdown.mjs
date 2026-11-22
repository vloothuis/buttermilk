// Golden fixtures for Markdown round trips: each document in markdown-corpus/ is parsed and
// serialized by a headless Milkdown editor with the commonmark and gfm presets.
import {readdirSync, readFileSync, writeFileSync, mkdirSync} from "node:fs"
import {JSDOM} from "jsdom"

const dom = new JSDOM("<!doctype html><div id=app></div>")
const events = new EventTarget()
for (const k of ["addEventListener", "removeEventListener", "dispatchEvent"]) globalThis[k] = events[k].bind(events)
for (const k of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "MutationObserver", "getComputedStyle", "DOMParser", "requestAnimationFrame"]) {
  if (!(k in globalThis)) globalThis[k] = typeof dom.window[k] === "function" && !/^[A-Z]/.test(k) ? dom.window[k].bind(dom.window) : dom.window[k]
}
const {Editor, rootCtx, serializerCtx, parserCtx} = await import("@milkdown/core")
const {commonmark} = await import("@milkdown/preset-commonmark")
const {gfm} = await import("@milkdown/preset-gfm")

const editor = await Editor.make().config(ctx => ctx.set(rootCtx, document.getElementById("app"))).use(commonmark).use(gfm).create()
const roundTrip = text => editor.action(ctx => ctx.get(serializerCtx)(ctx.get(parserCtx)(text)))

const cases = readdirSync("markdown-corpus").filter(f => f.endsWith(".md")).sort().map(file => {
  const input = readFileSync(`markdown-corpus/${file}`, "utf8")
  return {name: file.replace(/\.md$/, ""), input, milkdown: roundTrip(input)}
})

mkdirSync("../Tests/ButtermilkMarkdownTests/Fixtures", {recursive: true})
writeFileSync("../Tests/ButtermilkMarkdownTests/Fixtures/roundtrip.json", JSON.stringify({cases}, null, 1))
console.log("roundtrip:", cases.length, "cases")
process.exit(0)
