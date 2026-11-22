/// Something that can map positions through document changes.
public protocol Mappable {
    func map(_ pos: Int, assoc: Int) -> Int
    func mapResult(_ pos: Int, assoc: Int) -> MapResult
}

public extension Mappable {
    func map(_ pos: Int) -> Int { map(pos, assoc: 1) }
    func mapResult(_ pos: Int) -> MapResult { mapResult(pos, assoc: 1) }
}

private let factor16 = 1 << 16
private func makeRecover(_ index: Int, _ offset: Int) -> Int { index + offset * factor16 }
private func recoverIndex(_ value: Int) -> Int { value & 0xffff }
private func recoverOffset(_ value: Int) -> Int { (value - (value & 0xffff)) / factor16 }

/// The result of mapping a position, with information about deletions.
public struct MapResult {
    public struct DeletionInfo: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let before = DeletionInfo(rawValue: 1)
        public static let after = DeletionInfo(rawValue: 2)
        public static let across = DeletionInfo(rawValue: 4)
        public static let side = DeletionInfo(rawValue: 8)
    }

    public let pos: Int
    public let delInfo: DeletionInfo
    let recover: Int?

    public var deleted: Bool { delInfo.contains(.side) }
    public var deletedBefore: Bool { !delInfo.isDisjoint(with: [.before, .across]) }
    public var deletedAfter: Bool { !delInfo.isDisjoint(with: [.after, .across]) }
    public var deletedAcross: Bool { delInfo.contains(.across) }
}

/// A map describing the deletions and insertions made by a step.
public struct StepMap: Mappable, CustomStringConvertible, Equatable {
    public let ranges: [Int]
    public let inverted: Bool

    public init(_ ranges: [Int], inverted: Bool = false) {
        self.ranges = ranges
        self.inverted = inverted
    }

    public static let empty = StepMap([])

    public static func offset(_ n: Int) -> StepMap {
        n == 0 ? .empty : StepMap(n < 0 ? [0, -n, 0] : [0, 0, n])
    }

    func recover(_ value: Int) -> Int {
        var diff = 0
        let index = recoverIndex(value)
        if !inverted { for i in 0..<index { diff += ranges[i * 3 + 2] - ranges[i * 3 + 1] } }
        return ranges[index * 3] + diff + recoverOffset(value)
    }

    public func mapResult(_ pos: Int, assoc: Int) -> MapResult { _map(pos, assoc, simple: false).1! }
    public func map(_ pos: Int, assoc: Int) -> Int { _map(pos, assoc, simple: true).0 }

    private func _map(_ pos: Int, _ assoc: Int, simple: Bool) -> (Int, MapResult?) {
        var diff = 0
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var i = 0
        while i < ranges.count {
            let start = ranges[i] - (inverted ? diff : 0)
            if start > pos { break }
            let oldSize = ranges[i + oldIndex], newSize = ranges[i + newIndex], end = start + oldSize
            if pos <= end {
                let side = oldSize == 0 ? assoc : pos == start ? -1 : pos == end ? 1 : assoc
                let result = start + diff + (side < 0 ? 0 : newSize)
                if simple { return (result, nil) }
                let recover: Int? = pos == (assoc < 0 ? start : end) ? nil : makeRecover(i / 3, pos - start)
                var del: MapResult.DeletionInfo = []
                if oldSize > 0 {
                    del.insert(pos == start ? .after : pos == end ? .before : .across)
                    if assoc < 0 ? pos != start : pos != end { del.insert(.side) }
                }
                return (result, MapResult(pos: result, delInfo: del, recover: recover))
            }
            diff += newSize - oldSize
            i += 3
        }
        return simple ? (pos + diff, nil) : (pos + diff, MapResult(pos: pos + diff, delInfo: [], recover: nil))
    }

    func touches(_ pos: Int, _ recover: Int) -> Bool {
        var diff = 0
        let index = recoverIndex(recover)
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var i = 0
        while i < ranges.count {
            let start = ranges[i] - (inverted ? diff : 0)
            if start > pos { break }
            let oldSize = ranges[i + oldIndex], end = start + oldSize
            if pos <= end && i == index * 3 { return true }
            diff += ranges[i + newIndex] - oldSize
            i += 3
        }
        return false
    }

    /// Call `f` with `(oldStart, oldEnd, newStart, newEnd)` for each changed range.
    public func forEach(_ f: (Int, Int, Int, Int) -> Void) {
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var diff = 0, i = 0
        while i < ranges.count {
            let start = ranges[i], oldStart = start - (inverted ? diff : 0), newStart = start + (inverted ? 0 : diff)
            let oldSize = ranges[i + oldIndex], newSize = ranges[i + newIndex]
            f(oldStart, oldStart + oldSize, newStart, newStart + newSize)
            diff += newSize - oldSize
            i += 3
        }
    }

    public func invert() -> StepMap { StepMap(ranges, inverted: !inverted) }

    public var description: String {
        (inverted ? "-" : "") + "[" + ranges.map(String.init).joined(separator: ",") + "]"
    }
}

/// A pipeline of step maps, with support for mirroring (undo/redo of the same change).
public final class Mapping: Mappable {
    public private(set) var maps: [StepMap]
    var mirror: [Int]?
    public var from: Int
    public var to: Int

    public init(_ maps: [StepMap] = [], mirror: [Int]? = nil, from: Int = 0, to: Int? = nil) {
        self.maps = maps
        self.mirror = mirror
        self.from = from
        self.to = to ?? maps.count
    }

    public func slice(_ from: Int = 0, _ to: Int? = nil) -> Mapping {
        Mapping(maps, mirror: mirror, from: from, to: to ?? maps.count)
    }

    public func copy() -> Mapping { Mapping(maps, mirror: mirror, from: from, to: to) }

    public func appendMap(_ map: StepMap, mirrors: Int? = nil) {
        maps.append(map)
        to = maps.count
        if let mirrors { setMirror(maps.count - 1, mirrors) }
    }

    public func appendMapping(_ mapping: Mapping) {
        let startSize = maps.count
        for i in mapping.from..<max(mapping.from, mapping.to) {
            var mirr = mapping.getMirror(i)
            if let m = mirr { mirr = m < i && m >= mapping.from ? startSize + (m - mapping.from) : nil }
            appendMap(mapping.maps[i], mirrors: mirr)
        }
    }

    public func getMirror(_ n: Int) -> Int? {
        guard let mirror else { return nil }
        for (i, v) in mirror.enumerated() where v == n { return mirror[i + (i % 2 == 1 ? -1 : 1)] }
        return nil
    }

    func setMirror(_ n: Int, _ m: Int) {
        if mirror == nil { mirror = [] }
        mirror!.append(contentsOf: [n, m])
    }

    public func appendMappingInverted(_ mapping: Mapping) {
        let totalSize = maps.count + mapping.maps.count
        var i = mapping.to - 1
        while i >= mapping.from {
            var mirr = mapping.getMirror(i)
            if let m = mirr { mirr = m > i && m < mapping.to ? totalSize - (m - mapping.from) - 1 : nil }
            appendMap(mapping.maps[i].invert(), mirrors: mirr)
            i -= 1
        }
    }

    public func invert() -> Mapping {
        let inverse = Mapping()
        inverse.appendMappingInverted(self)
        return inverse
    }

    public func map(_ pos: Int, assoc: Int) -> Int {
        if mirror != nil { return _map(pos, assoc).pos }
        var pos = pos
        for i in from..<max(from, to) { pos = maps[i].map(pos, assoc: assoc) }
        return pos
    }

    public func mapResult(_ pos: Int, assoc: Int) -> MapResult { _map(pos, assoc) }

    private func _map(_ pos: Int, _ assoc: Int) -> MapResult {
        var pos = pos
        var delInfo: MapResult.DeletionInfo = []
        var i = from
        while i < to {
            let map = maps[i], result = map.mapResult(pos, assoc: assoc)
            if let rec = result.recover, let corr = getMirror(i), corr > i, corr < to {
                i = corr
                pos = maps[corr].recover(rec)
                i += 1
                continue
            }
            delInfo.formUnion(result.delInfo)
            pos = result.pos
            i += 1
        }
        return MapResult(pos: pos, delInfo: delInfo, recover: nil)
    }
}
