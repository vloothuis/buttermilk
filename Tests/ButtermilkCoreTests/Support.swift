import Foundation
import XCTest
@testable import ButtermilkCore

let testSchema: Schema = try! Schema(
    nodeList: ListSchema.addListNodes(BasicSchema.nodes, itemContent: "paragraph block*", listGroup: "block"),
    markList: BasicSchema.marks)

func loadFixture(_ name: String) -> JSON {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! JSON(data: Data(contentsOf: url))
}

extension JSON {
    var int: Int { intValue! }
    var string: String { stringValue! }
    var array: [JSON] { arrayValue ?? [] }
}

/// Collects mismatches so one run reports many failures without flooding the log.
final class Mismatches {
    var count = 0
    var shown = 0
    let limit: Int
    init(limit: Int = 25) { self.limit = limit }

    func check(_ ok: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        if ok { return }
        count += 1
        if shown < limit {
            shown += 1
            XCTFail(message(), file: file, line: line)
        }
    }

    func equal(_ a: JSON?, _ b: JSON?, _ context: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        let na = normalize(a), nb = normalize(b)
        check(na == nb, "\(context())\n  swift: \(na.map(\.description) ?? "nil")\n  js:    \(nb.map(\.description) ?? "nil")",
              file: file, line: line)
    }

    func finish(_ name: String, total: Int) {
        print("[\(name)] \(total - count)/\(total) checks passed")
    }
}

/// Treat `null` and a missing value as the same.
func normalize(_ j: JSON?) -> JSON? {
    guard let j else { return nil }
    switch j {
    case .null: return nil
    case .object(let o):
        var r: [String: JSON] = [:]
        for (k, v) in o { if let n = normalize(v) { r[k] = n } }
        return .object(r)
    case .array(let a): return .array(a.map { normalize($0) ?? .null })
    default: return j
    }
}


