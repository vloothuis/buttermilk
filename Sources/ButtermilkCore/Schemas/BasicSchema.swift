/// Port of `prosemirror-schema-basic`: a simple schema with common block and inline nodes.
public enum BasicSchema {
    public static let nodes: [(String, NodeSpec)] = [
        ("doc", NodeSpec(content: "block+")),
        ("paragraph", NodeSpec(content: "inline*", group: "block")),
        ("blockquote", NodeSpec(content: "block+", group: "block", defining: true)),
        ("horizontal_rule", NodeSpec(group: "block")),
        ("heading", NodeSpec(content: "inline*", group: "block",
                             attrs: ["level": AttributeSpec(default: 1, validateType: "number")], defining: true)),
        ("code_block", NodeSpec(content: "text*", marks: "", group: "block", code: true, defining: true)),
        ("text", NodeSpec(group: "inline")),
        ("image", NodeSpec(group: "inline", inline: true,
                           attrs: ["src": AttributeSpec(validateType: "string"),
                                   "alt": AttributeSpec(default: .null, validateType: "string|null"),
                                   "title": AttributeSpec(default: .null, validateType: "string|null")],
                           draggable: true)),
        ("hard_break", NodeSpec(group: "inline", inline: true, selectable: false)),
    ]

    public static let marks: [(String, MarkSpec)] = [
        ("link", MarkSpec(attrs: ["href": AttributeSpec(validateType: "string"),
                                  "title": AttributeSpec(default: .null, validateType: "string|null")],
                          inclusive: false)),
        ("em", MarkSpec()),
        ("strong", MarkSpec()),
        ("code", MarkSpec(code: true)),
    ]

    /// The basic schema.
    public static let schema: Schema = try! Schema(nodeList: nodes, markList: marks)
}

/// Port of the node specs from `prosemirror-schema-list`.
public enum ListSchema {
    public static let orderedList = NodeSpec(attrs: ["order": AttributeSpec(default: 1, validateType: "number")])
    public static let bulletList = NodeSpec()
    public static let listItem = NodeSpec(defining: true)

    /// Append list node types to a node list, as `addListNodes` does.
    public static func addListNodes(_ nodes: [(String, NodeSpec)], itemContent: String, listGroup: String? = nil) -> [(String, NodeSpec)] {
        var ol = orderedList, bl = bulletList, li = listItem
        ol.content = "list_item+"; ol.group = listGroup
        bl.content = "list_item+"; bl.group = listGroup
        li.content = itemContent
        return nodes + [("ordered_list", ol), ("bullet_list", bl), ("list_item", li)]
    }
}
