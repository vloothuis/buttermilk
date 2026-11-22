#if canImport(SwiftUI)
import ButtermilkCore
import SwiftUI

/// A SwiftUI editor bound to an ``EditorState``.
///
/// ```swift
/// @State var state = try! EditorState.create(.init(schema: BasicSchema.schema))
/// var body: some View { ButtermilkEditor(state: $state) }
/// ```
public struct ButtermilkEditor {
    @Binding var state: EditorState
    var theme: Theme

    public init(state: Binding<EditorState>, theme: Theme = .standard) {
        _state = state
        self.theme = theme
    }

    public final class Coordinator {
        var parent: ButtermilkEditor
        var isPublishing = false
        init(_ parent: ButtermilkEditor) { self.parent = parent }

        func connect(_ view: ButtermilkTextView) {
            view.core.onChangeObservers.append { [weak self] next, _ in
                guard let self, !self.isPublishing else { return }
                self.isPublishing = true
                self.parent.state = next
                self.isPublishing = false
            }
        }

        func update(_ view: ButtermilkTextView, _ state: EditorState) {
            guard view.core.state !== state, !isPublishing else { return }
            isPublishing = true
            view.core.update(state)
            isPublishing = false
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension ButtermilkEditor: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSScrollView {
        let textView = ButtermilkTextView(state: state, theme: theme)
        context.coordinator.connect(textView)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        scroll.documentView = textView
        return scroll
    }

    public func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = view.documentView as? ButtermilkTextView else { return }
        context.coordinator.update(textView, state)
    }
}
#elseif canImport(UIKit)
extension ButtermilkEditor: UIViewRepresentable {
    public func makeUIView(context: Context) -> ButtermilkTextView {
        let view = ButtermilkTextView(state: state, theme: theme)
        view.backgroundColor = .clear
        context.coordinator.connect(view)
        return view
    }

    public func updateUIView(_ view: ButtermilkTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view, state)
    }
}
#endif
#endif
