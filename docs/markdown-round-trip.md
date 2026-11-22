# Markdown round trips compared with Milkdown

`MarkdownConverter` parses Markdown and writes it back in the style of Milkdown's remark
serializer. `RoundTripGoldenTests` checks this on the documents in `golden/markdown-corpus`.
`golden/gen-markdown.mjs` runs each document through a headless Milkdown editor with the
CommonMark and GFM presets and saves the output in
`Tests/ButtermilkMarkdownTests/Fixtures/roundtrip.json`.

Both write `*` bullets, `***` rules, fenced code blocks, `\` hard breaks, ATX headings, padded
tables and blank lines only in loose lists. Both escape the same characters in the corpus.

## Intentional differences

These are the differences the test allows. Each one is listed in `RoundTripGoldenTests.differences`.

- **Soft line breaks.** Buttermilk turns a line break inside a paragraph into a space. Milkdown keeps
  the newline in the text. The rendered Markdown is the same.
- **Emphasis markers.** Buttermilk writes `*em*` and `**strong**`. Milkdown remembers whether the
  source used `_` or `*` and writes the same marker back.
- **Front matter.** Buttermilk keeps YAML front matter unchanged. Milkdown's presets do not support
  front matter, so it reads the block as a rule and a heading.
- **Adjacent lists.** Two lists of the same kind in a row must not merge when read back. Buttermilk
  switches the marker (`*` then `-`, or `1.` then `1)`). Milkdown also switches bullet markers, but
  keeps an HTML comment between ordered lists. Buttermilk drops HTML comments between blocks.
- **Empty list items.** Buttermilk writes the marker alone. Milkdown writes `* <br />`.

## Other differences

The corpus does not cover these, or Milkdown's output is wrong in them.

- **Raw HTML.** Buttermilk has no HTML node, so HTML becomes text and is written back as is. For the
  same reason it never escapes `<`. Milkdown escapes `<` in text when a letter follows.
- **Tildes.** Buttermilk escapes every `~`, because cmark-gfm reads `~text~` as strikethrough.
  Milkdown escapes `~` only at the start of a line.
- **Pipes in table code.** Buttermilk writes `|` inside inline code in a table cell as `\|`, as GFM
  requires. Milkdown writes `` `a|b` `` and breaks the table.
- **Backslashes.** Buttermilk escapes a backslash only before ASCII punctuation or at the end of a
  text run. Milkdown sometimes adds extra backslashes.
- **Table cell spans.** GFM tables have no spans. Buttermilk writes a spanning cell followed by empty
  cells.
- **Character width in tables.** Buttermilk pads cells by character count. Milkdown pads by UTF-16
  length, so columns with emoji can differ by a space.
