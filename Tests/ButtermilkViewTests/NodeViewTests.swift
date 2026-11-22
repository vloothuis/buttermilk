#if canImport(AppKit)
import AppKit
import ButtermilkCore
@testable import ButtermilkView
import XCTest

/// A node view with a text field that edits the image's `alt` attribute.
final class AltField: NSObject, NodeView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    var view: NSView { field }
    var size: CGSize = CGSize(width: 80, height: 20)
    let editor: EditorViewing
    let getPos: () -> Int?
    var acceptsUpdates = true
    var updates = 0, destroyed = false, selected = false

    init(_ node: Node, _ editor: EditorViewing, _ getPos: @escaping () -> Int?) {
        self.editor = editor; self.getPos = getPos
        super.init()
        field.stringValue = node.attrs["alt"]?.stringValue ?? ""
        field.delegate = self
    }

    func update(_ node: Node, _ decorations: [Decoration]) -> Bool {
        guard acceptsUpdates else { return false }
        updates += 1
        field.stringValue = node.attrs["alt"]?.stringValue ?? ""
        return true
    }

    func selectNode() { selected = true }
    func deselectNode() { selected = false }
    func destroy() { destroyed = true }

    /// Writes the field back to the document.
    func commit() {
        guard let pos = getPos(), let tr = try? editor.state.tr.setNodeAttribute(pos, "alt", .string(field.stringValue)) else { return }
        editor.dispatch(tr)
    }

    func controlTextDidChange(_ obj: Notification) { commit() }
}

final class NodeViewTests: XCTestCase {
    let schema = BasicSchema.schema
    var made: [AltField] = []

    func makeView(_ content: [JSON], cursor: Int = 1) throws -> ButtermilkTextView {
        let doc = try schema.nodeFromJSON(["type": "doc", "content": .array(content)])
        var config = EditorState.Config(doc: doc)
        config.selection = TextSelection.between(doc.resolve(cursor), doc.resolve(cursor))
        let view = ButtermilkTextView(state: try EditorState.create(config))
        view.core.nodeViews = ["image": { [unowned self] node, editor, getPos in
            let v = AltField(node, editor, getPos); self.made.append(v); return v
        }]
        return view
    }

    let image: JSON = ["type": "image", "attrs": ["src": "a.png", "alt": "cat"]]
    func para(_ content: JSON...) -> JSON { ["type": "paragraph", "content": .array(content)] }
    func text(_ s: String) -> JSON { ["type": "text", "text": .string(s)] }

    func testCreatesAViewOverTheAttachment() throws {
        let view = try makeView([para(text("ab"), image, text("c"))])
        XCTAssertEqual(made.count, 1)
        let nodeView = made[0]
        XCTAssertTrue(nodeView.field.superview === view)
        XCTAssertEqual(nodeView.field.stringValue, "cat")
        XCTAssertEqual(nodeView.getPos(), 3)
        XCTAssertEqual(view.core.position(of: nodeView), 3)
        let attachment = view.textStorage?.attribute(.attachment, at: 2, effectiveRange: nil) as? NodeViewAttachment
        XCTAssertEqual(attachment?.bounds.size, nodeView.size)
        XCTAssertEqual(nodeView.field.frame.size, nodeView.size)
        XCTAssertGreaterThan(nodeView.field.frame.minX, view.textContainerOrigin.x)
        XCTAssertEqual(view.nodeViews.count, 1)
    }

    func testKeepsTheViewWhenTextAroundItChanges() throws {
        let view = try makeView([para(text("ab"), image, text("c"))], cursor: 1)
        let nodeView = made[0]
        let x = nodeView.field.frame.minX
        view.insertText("xy", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(made.count, 1)
        XCTAssertFalse(nodeView.destroyed)
        XCTAssertEqual(nodeView.getPos(), 5)
        XCTAssertGreaterThan(nodeView.field.frame.minX, x)
    }

    func testUpdatesOrReplacesTheViewWhenTheNodeChanges() throws {
        let view = try makeView([para(text("ab"), image)])
        let first = made[0]
        view.dispatch(try view.state.tr.setNodeAttribute(3, "alt", "dog"))
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(first.updates, 1)
        XCTAssertEqual(first.field.stringValue, "dog")
        XCTAssertEqual(first.getPos(), 3)

        first.acceptsUpdates = false
        view.dispatch(try view.state.tr.setNodeAttribute(3, "alt", "eel"))
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(first.destroyed)
        XCTAssertNil(first.field.superview)
        XCTAssertNil(first.getPos())
        XCTAssertEqual(made[1].field.stringValue, "eel")
        XCTAssertEqual(made[1].getPos(), 3)
    }

    func testDestroysTheViewWhenTheNodeIsDeleted() throws {
        let view = try makeView([para(text("ab"), image)])
        view.dispatch(try view.state.tr.delete(3, 4))
        XCTAssertTrue(made[0].destroyed)
        XCTAssertNil(made[0].field.superview)
        XCTAssertTrue(view.nodeViews.isEmpty)
    }

    func testSelectsAndDeselectsTheNode() throws {
        let view = try makeView([para(text("ab"), image)])
        view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, 3)))
        XCTAssertTrue(made[0].selected)
        view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 1)))
        XCTAssertFalse(made[0].selected)
    }

    func testTakesFocusAndHandlesItsOwnInput() throws {
        let view = try makeView([para(text("ab"), image)])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let field = made[0].field
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.firstResponder === view)
        // Typing in the field edits the field, not the text, and the view writes the change back.
        field.currentEditor()?.moveToEndOfDocument(nil)
        field.currentEditor()?.insertText("s")
        XCTAssertEqual(view.state.doc.textContent, "ab")
        made[0].commit()
        XCTAssertEqual(view.state.doc.nodeAt(3)?.attrs["alt"]?.stringValue, "cats")
        XCTAssertEqual(made.count, 1)
    }

    func testBlockLeafNodeView() throws {
        let view = try makeView([para(text("a")), ["type": "horizontal_rule"]])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        final class Rule: NodeView { let view: NSView; init(_ v: NSView) { view = v } }
        view.core.nodeViews["horizontal_rule"] = { _, _, _ in Rule(box) }
        XCTAssertTrue(box.superview === view)
        XCTAssertEqual(box.frame.size, CGSize(width: 200, height: 40))
        XCTAssertEqual(view.core.position(of: view.nodeViews.last!), 3)
    }

    func testNoNodeViewsLeavesRenderingAlone() throws {
        let view = try makeView([para(text("ab"), image)])
        view.core.nodeViews = [:]
        XCTAssertTrue(made[0].destroyed)
        XCTAssertFalse(view.textStorage?.attribute(.attachment, at: 2, effectiveRange: nil) is NodeViewAttachment)
    }
}
#endif
