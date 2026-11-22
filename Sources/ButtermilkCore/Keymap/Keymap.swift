/// Key bindings, as in prosemirror-keymap. Binding names look like `"Mod-b"`, `"Shift-Enter"`,
/// or `"Ctrl-Alt-Backspace"`. `Mod` is Command on Apple platforms and Control elsewhere.
public enum Keymap {
    #if os(macOS) || os(iOS) || os(visionOS)
    static let isApple = true
    #else
    static let isApple = false
    #endif

    /// Normalise a binding name to the form `Shift-Meta-Ctrl-Alt-key`. Throws on unknown modifiers.
    public static func normalizeKeyName(_ name: String) throws -> String {
        // Split on "-" except a trailing one, so "Mod--" means Mod and "-".
        var parts: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            if c == "-" && i < chars.count - 1 && !current.isEmpty { parts.append(current); current = "" } else { current.append(c) }
        }
        parts.append(current)
        var result = parts.removeLast()
        if result == "Space" { result = " " }
        var alt = false, ctrl = false, shift = false, meta = false
        for mod in parts {
            switch mod.lowercased() {
            case "cmd", "meta", "m": meta = true
            case "a", "alt": alt = true
            case "c", "ctrl", "control": ctrl = true
            case "s", "shift": shift = true
            case "mod": if isApple { meta = true } else { ctrl = true }
            default: throw ProseError.range("Unrecognized modifier name: \(mod)")
            }
        }
        if alt { result = "Alt-" + result }
        if ctrl { result = "Ctrl-" + result }
        if meta { result = "Meta-" + result }
        if shift { result = "Shift-" + result }
        return result
    }

    static func modifiers(_ name: String, _ event: KeyPress, shift: Bool = true) -> String {
        var name = name
        if event.modifiers.contains(.option) { name = "Alt-" + name }
        if event.modifiers.contains(.control) { name = "Ctrl-" + name }
        if event.modifiers.contains(.command) { name = "Meta-" + name }
        if shift && event.modifiers.contains(.shift) { name = "Shift-" + name }
        return name
    }

    /// Normalise the binding names. A binding with an unknown modifier is a programming error.
    static func normalize(_ bindings: [String: Command]) -> [String: Command] {
        var copy: [String: Command] = [:]
        for (k, v) in bindings {
            guard let n = try? normalizeKeyName(k) else { preconditionFailure("Unrecognized key binding \(k)") }
            copy[n] = v
        }
        return copy
    }

    /// A key handler for the bindings, for use as `handleKeyDown`.
    public static func handler(_ bindings: [String: Command]) -> (EditorViewing, KeyPress) -> Bool {
        let map = normalize(bindings)
        return { view, event in
            let name = event.key
            func run(_ c: Command?) -> Bool { c?(view.state, view.dispatch, view) ?? false }
            if run(map[modifiers(name, event)]) { return true }
            if name.utf16.count == 1 && name != " " {
                if event.modifiers.contains(.shift), run(map[modifiers(name, event, shift: false)]) { return true }
                if !event.modifiers.isDisjoint(with: [.option, .command, .control]),
                   let base = event.baseKey, base != name, run(map[modifiers(base, event)]) {
                    return true
                }
            }
            return false
        }
    }

    /// A plugin that handles the given key bindings.
    public static func plugin(_ bindings: [String: Command]) -> Plugin {
        var props = EditorProps()
        props.handleKeyDown = handler(bindings)
        return Plugin(props: props)
    }
}
