import ButtermilkCore

/// A schema for CommonMark plus the GitHub extensions (tables, strikethrough, task lists) and
/// YAML front matter.
///
/// It covers what Milkdown's CommonMark and GFM presets cover. Node and mark names follow the
/// ProseMirror basic, list and table schemas, so ``ButtermilkView`` renders it as is.
public enum MarkdownSchema {
    public static let nodes: [(String, NodeSpec)] = {
        var nodes = BasicSchema.nodes.filter { $0.0 != "code_block" }
        nodes.insert(("code_block", NodeSpec(content: "text*", marks: "", group: "block",
                                             attrs: ["language": AttributeSpec(default: "", validateType: "string")],
                                             code: true, defining: true)), at: 4)
        // The raw YAML between the `---` fences at the start of a document.
        nodes.insert(("front_matter", NodeSpec(content: "text*", marks: "", group: "block",
                                               code: true, defining: true)), at: 5)
        nodes = ListSchema.addListNodes(nodes, itemContent: "paragraph block*", listGroup: "block")
        // `spread` marks loose lists and items, whose children are separated by blank lines.
        for i in nodes.indices where ["bullet_list", "ordered_list", "list_item"].contains(nodes[i].0) {
            nodes[i].1.attrs["spread"] = AttributeSpec(default: .bool(false), validateType: "boolean")
            if nodes[i].0 == "list_item" { nodes[i].1.attrs["checked"] = AttributeSpec(default: .null, validateType: "boolean|null") }
        }
        return nodes + Tables.nodes(cellContent: "paragraph",
                                    cellAttributes: ["alignment": .init(default: .null)],
                                    tableGroup: "block")
    }()

    public static let marks: [(String, MarkSpec)] = BasicSchema.marks + [("strike_through", MarkSpec())]

    public static let schema: Schema = try! Schema(nodeList: nodes, markList: marks)
}
