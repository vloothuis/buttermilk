import ButtermilkCore
import Foundation
#if canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
#elseif canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
#endif

/// A host-supplied view for a leaf node, as in `prosemirror-view`.
///
/// The node renders as one attachment character that reserves ``size``. The editor view adds
/// ``view`` as a subview over that character, so the view can take focus and handle its own
/// mouse and key input. Changes to the node go through transactions, using the position that
/// the constructor's `getPos` returns.
public protocol NodeView: AnyObject {
    /// The view shown in place of the node.
    var view: PlatformView { get }
    /// The space the node takes in the text. The default is the view's frame size.
    var size: CGSize { get }
    /// Called when the node or its node decorations change. Return true if the view showed the
    /// new node; return false to have it replaced by a new node view. The default returns false.
    func update(_ node: Node, _ decorations: [Decoration]) -> Bool
    /// Called when a node selection selects the node.
    func selectNode()
    /// Called when the node selection leaves the node.
    func deselectNode()
    /// Called when the node view is removed.
    func destroy()
}

public extension NodeView {
    var size: CGSize { view.frame.size }
    func update(_ node: Node, _ decorations: [Decoration]) -> Bool { false }
    func selectNode() {}
    func deselectNode() {}
    func destroy() {}
}

/// Makes a node view. `getPos` returns the node's current position, or nil once the node view
/// is removed.
public typealias NodeViewConstructor = (_ node: Node, _ view: EditorViewing, _ getPos: @escaping () -> Int?) -> NodeView

/// The attachment that stands in for a node with a node view.
public final class NodeViewAttachment: NSTextAttachment {
    public let node: Node

    init(_ node: Node) {
        self.node = node
        super.init(data: nil, ofType: nil)
        // An empty image, so the platform draws no placeholder icon under the view.
        image = PlatformImage.empty
        bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension PlatformImage {
    static let empty: PlatformImage = {
        #if canImport(AppKit)
        return NSImage(size: NSSize(width: 1, height: 1))
        #else
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #endif
    }()
}

/// Keeps one node view per ``NodeViewAttachment`` in the rendered text.
final class NodeViewManager {
    final class Entry {
        let attachment: NodeViewAttachment
        let nodeView: NodeView
        var node: Node
        var decorations: [Decoration]
        var offset: Int
        var selected = false
        init(_ attachment: NodeViewAttachment, _ nodeView: NodeView, _ node: Node, _ decorations: [Decoration], _ offset: Int) {
            self.attachment = attachment; self.nodeView = nodeView; self.node = node
            self.decorations = decorations; self.offset = offset
        }
    }

    /// Live entries, sorted by text offset.
    private(set) var entries: [Entry] = []

    /// Matches entries to the attachments in `text`: keeps those whose attachment is still there,
    /// reuses removed ones whose ``NodeView/update(_:_:)`` accepts a new node, creates the rest
    /// and destroys what is left. Returns the entries whose attachment got a new size.
    func sync(_ text: NSAttributedString, core: EditorCore, host: EditorViewing,
              constructors: [String: NodeViewConstructor]) -> [Entry] {
        var byAttachment: [ObjectIdentifier: Entry] = [:]
        entries.forEach { byAttachment[ObjectIdentifier($0.attachment)] = $0 }
        var found: [(NodeViewAttachment, Int)] = []
        if !constructors.isEmpty {
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let a = value as? NodeViewAttachment else { return }
                for i in 0..<range.length { found.append((a, range.location + i)) }
            }
        }
        var next: [Entry] = [], fresh: [(NodeViewAttachment, Int)] = []
        for (a, offset) in found {
            if let entry = byAttachment.removeValue(forKey: ObjectIdentifier(a)) {
                entry.offset = offset
                next.append(entry)
            } else {
                fresh.append((a, offset))
            }
        }
        var removed = entries.filter { byAttachment[ObjectIdentifier($0.attachment)] != nil }
        var resized: [Entry] = []
        let map = core.rendered.map
        for (a, offset) in fresh {
            let node = a.node, pos = map.position(for: offset)
            let decos = core.decorations.find(pos, pos + node.nodeSize).filter {
                $0.isNode && $0.from == pos && $0.to == pos + node.nodeSize
            }
            var entry: Entry?
            if let i = removed.firstIndex(where: { $0.node.type === node.type && (($0.node === node && $0.decorations == decos)
                || $0.nodeView.update(node, decos)) }) {
                let old = removed.remove(at: i)
                entry = Entry(a, old.nodeView, node, decos, offset)
                entry?.selected = old.selected
            } else if let make = constructors[node.type.name] {
                // getPos looks the node view up, so it stays right when an update reuses it.
                weak var made: NodeView?
                let nodeView = make(node, host) { [weak self, weak core] in
                    guard let self, let core, let made else { return nil }
                    return self.position(of: made, in: core.rendered.map)
                }
                made = nodeView
                entry = Entry(a, nodeView, node, decos, offset)
            }
            guard let entry else { continue }
            a.bounds = CGRect(origin: .zero, size: entry.nodeView.size)
            next.append(entry)
            resized.append(entry)
        }
        for entry in removed {
            entry.nodeView.view.removeFromSuperview()
            entry.nodeView.destroy()
        }
        next.sort { $0.offset < $1.offset }
        entries = next
        return resized
    }

    /// The current position of `nodeView`, or nil when it is not shown.
    func position(of nodeView: NodeView, in map: PositionMap) -> Int? {
        entries.first { $0.nodeView === nodeView }.map { map.position(for: $0.offset) }
    }

    /// Calls ``NodeView/selectNode()`` and ``NodeView/deselectNode()`` for a new selection.
    func updateSelection(_ selection: Selection, _ map: PositionMap) {
        let selectedPos = (selection as? NodeSelection)?.from
        for entry in entries {
            let isSelected = selectedPos != nil && map.position(for: entry.offset) == selectedPos
            if isSelected == entry.selected { continue }
            entry.selected = isSelected
            isSelected ? entry.nodeView.selectNode() : entry.nodeView.deselectNode()
        }
    }

    func destroyAll() {
        entries.forEach { $0.nodeView.view.removeFromSuperview(); $0.nodeView.destroy() }
        entries = []
    }
}
