/// Errors thrown by the document model and transforms.
///
/// These correspond to the `RangeError`, `ReplaceError`, and `SyntaxError`
/// exceptions thrown by ProseMirror.
public enum ProseError: Error, Equatable, CustomStringConvertible {
    /// An invalid value, position, or structure was supplied (`RangeError`).
    case range(String)
    /// A replace operation produced invalid content (`ReplaceError`).
    case replace(String)
    /// A schema content or mark expression could not be parsed (`SyntaxError`).
    case syntax(String)

    public var message: String {
        switch self {
        case .range(let m), .replace(let m), .syntax(let m): return m
        }
    }

    public var description: String { message }
}
