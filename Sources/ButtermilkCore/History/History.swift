import Foundation

// Port of prosemirror-history. Branches use plain arrays instead of a rope.

private let maxEmptyItems = 500
private let depthOverflow = 20

/// Iterate `items` like RopeSequence.forEach: forward over `from..<to`, or backward from
/// `from - 1` down to `to` when `from > to`. The callback returns false to stop.
private func iterate(_ items: [HistoryItem], _ from: Int, _ to: Int, _ f: (HistoryItem, Int) -> Bool) {
    if from <= to {
        var i = from
        while i < to { if !f(items[i], i) { return }; i += 1 }
    } else {
        var i = from - 1
        while i >= to { if !f(items[i], i) { return }; i -= 1 }
    }
}

struct HistoryItem {
    let map: StepMap
    let step: Step?
    let selection: SelectionBookmark?
    let mirrorOffset: Int?
    /// The action name of the event this item starts. Only set on items with a selection.
    let name: String?

    init(_ map: StepMap, _ step: Step? = nil, _ selection: SelectionBookmark? = nil, _ mirrorOffset: Int? = nil,
         name: String? = nil) {
        self.map = map; self.step = step; self.selection = selection; self.mirrorOffset = mirrorOffset
        self.name = selection == nil ? nil : name
    }

    func merge(_ other: HistoryItem) -> HistoryItem? {
        guard let step, let otherStep = other.step, other.selection == nil,
              let merged = otherStep.merge(step) else { return nil }
        return HistoryItem(merged.getMap().invert(), merged, selection, name: name)
    }
}

struct Branch {
    let items: [HistoryItem]
    let eventCount: Int

    static let empty = Branch(items: [], eventCount: 0)

    /// The action name of the last event.
    var lastEventName: String? {
        guard eventCount > 0 else { return nil }
        return items.last(where: { $0.selection != nil })?.name
    }

    func popEvent(_ state: EditorState, _ preserveItems: Bool) -> (remaining: Branch, transform: Transaction, selection: SelectionBookmark, name: String?)? {
        if eventCount == 0 { return nil }
        var end = items.count
        while true {
            if items[end - 1].selection != nil { end -= 1; break }
            end -= 1
        }
        var remap: Mapping?, mapFrom = 0
        if preserveItems {
            remap = remapping(end, items.count)
            mapFrom = remap!.maps.count
        }
        let transform = state.tr
        var selection: SelectionBookmark?, remaining: Branch?, name: String?
        var addAfter: [HistoryItem] = [], addBefore: [HistoryItem] = []

        iterate(items, items.count, 0) { item, i in
            guard let itemStep = item.step else {
                if remap == nil {
                    remap = remapping(end, i + 1)
                    mapFrom = remap!.maps.count
                }
                mapFrom -= 1
                addBefore.append(item)
                return true
            }
            if let r = remap {
                addBefore.append(HistoryItem(item.map))
                var map: StepMap?
                if let step = itemStep.map(r.slice(mapFrom)), transform.maybeStep(step).doc != nil {
                    map = transform.mapping.maps[transform.mapping.maps.count - 1]
                    addAfter.append(HistoryItem(map!, nil, nil, addAfter.count + addBefore.count))
                }
                mapFrom -= 1
                if let map { r.appendMap(map, mirrors: mapFrom) }
            } else {
                transform.maybeStep(itemStep)
            }
            if let sel = item.selection {
                selection = remap.map { sel.map($0.slice(mapFrom)) } ?? sel
                name = item.name
                remaining = Branch(items: Array(items[0..<end]) + addBefore.reversed() + addAfter, eventCount: eventCount - 1)
                return false
            }
            return true
        }
        return (remaining!, transform, selection!, name)
    }

    func addTransform(_ transform: Transform, _ selection: SelectionBookmark?, _ options: HistoryOptions, _ preserveItems: Bool,
                      name: String? = nil) -> Branch {
        var newItems: [HistoryItem] = []
        var eventCount = self.eventCount
        var oldItems = items
        var lastItem = !preserveItems ? oldItems.last : nil
        var selection = selection
        for i in 0..<transform.steps.count {
            let step = transform.steps[i].invert(transform.docs[i])
            var item = HistoryItem(transform.mapping.maps[i], step, selection, name: name)
            if let merged = lastItem?.merge(item) {
                item = merged
                if i > 0 { newItems.removeLast() } else { oldItems.removeLast() }
            }
            newItems.append(item)
            if selection != nil {
                eventCount += 1
                selection = nil
            }
            if !preserveItems { lastItem = item }
        }
        let overflow = eventCount - options.depth
        if overflow > depthOverflow {
            oldItems = cutOffEvents(oldItems, overflow)
            eventCount -= overflow
        }
        return Branch(items: oldItems + newItems, eventCount: eventCount)
    }

    func remapping(_ from: Int, _ to: Int) -> Mapping {
        let maps = Mapping()
        iterate(items, from, to) { item, i in
            let mirrorPos = item.mirrorOffset.flatMap { i - $0 >= from ? maps.maps.count - $0 : nil }
            maps.appendMap(item.map, mirrors: mirrorPos)
            return true
        }
        return maps
    }

    func addMaps(_ array: [StepMap]) -> Branch {
        if eventCount == 0 { return self }
        return Branch(items: items + array.map { HistoryItem($0) }, eventCount: eventCount)
    }

    func rebased(_ rebasedTransform: Transform, _ rebasedCount: Int) -> Branch {
        if eventCount == 0 { return self }
        let rebasedCount = Swift.min(items.count, rebasedCount)
        var rebasedItems: [HistoryItem] = []
        let start = items.count - rebasedCount
        let mapping = rebasedTransform.mapping
        var newUntil = rebasedTransform.steps.count
        var eventCount = self.eventCount
        iterate(items, start, items.count) { item, _ in if item.selection != nil { eventCount -= 1 }; return true }
        var iRebased = rebasedCount
        iterate(items, start, items.count) { item, _ in
            iRebased -= 1
            guard let pos = mapping.getMirror(iRebased) else { return true }
            newUntil = Swift.min(newUntil, pos)
            let map = mapping.maps[pos]
            if item.step != nil {
                let step = rebasedTransform.steps[pos].invert(rebasedTransform.docs[pos])
                let selection = item.selection.map { $0.map(mapping.slice(iRebased + 1, pos)) }
                if selection != nil { eventCount += 1 }
                rebasedItems.append(HistoryItem(map, step, selection, name: item.name))
            } else {
                rebasedItems.append(HistoryItem(map))
            }
            return true
        }
        var newMaps: [HistoryItem] = []
        if rebasedCount < newUntil { for i in rebasedCount..<newUntil { newMaps.append(HistoryItem(mapping.maps[i])) } }
        var branch = Branch(items: Array(items[0..<start]) + newMaps + rebasedItems, eventCount: eventCount)
        if branch.emptyItemCount() > maxEmptyItems { branch = branch.compress(items.count - rebasedItems.count) }
        return branch
    }

    func emptyItemCount() -> Int { items.filter { $0.step == nil }.count }

    func compress(_ upto: Int? = nil) -> Branch {
        let upto = upto ?? items.count
        let remap = remapping(0, upto)
        var mapFrom = remap.maps.count
        var result: [HistoryItem] = []
        var events = 0
        iterate(items, items.count, 0) { item, i in
            if i >= upto {
                result.append(item)
                if item.selection != nil { events += 1 }
            } else if let itemStep = item.step {
                let step = itemStep.map(remap.slice(mapFrom)), map = step?.getMap()
                mapFrom -= 1
                if let map { remap.appendMap(map, mirrors: mapFrom) }
                if let step {
                    let selection = item.selection.map { $0.map(remap.slice(mapFrom)) }
                    if selection != nil { events += 1 }
                    let newItem = HistoryItem(map!.invert(), step, selection, name: item.name)
                    if let last = result.last, let merged = last.merge(newItem) {
                        result[result.count - 1] = merged
                    } else {
                        result.append(newItem)
                    }
                }
            } else {
                mapFrom -= 1
            }
            return true
        }
        return Branch(items: result.reversed(), eventCount: events)
    }
}

private func cutOffEvents(_ items: [HistoryItem], _ n: Int) -> [HistoryItem] {
    var n = n
    var cutPoint = 0
    for (i, item) in items.enumerated() where item.selection != nil {
        if n == 0 { cutPoint = i; break }
        n -= 1
    }
    return Array(items[cutPoint...])
}

/// The state of the history plugin.
public struct HistoryState {
    let done: Branch
    let undone: Branch
    let prevRanges: [Int]?
    let prevTime: Double
    let prevComposition: Int
}

/// Options for ``History/plugin(_:)``.
public struct HistoryOptions {
    /// The number of events to keep. Default 100.
    public var depth: Int
    /// Changes within this many milliseconds of each other are grouped. Default 500.
    public var newGroupDelay: Double
    public init(depth: Int = 100, newGroupDelay: Double = 500) { self.depth = depth; self.newGroupDelay = newGroupDelay }
}

struct HistoryMeta {
    let redo: Bool
    let historyState: HistoryState
}

/// Undo history.
public enum History {
    static let key = PluginKey<HistoryState>("history")
    static let closeKey = PluginKey<Bool>("closeHistory")

    /// The history plugin. Add it to the editor state to enable ``undo`` and ``redo``.
    public static func plugin(_ options: HistoryOptions = .init()) -> Plugin {
        Plugin(key: key,
               state: StateField<HistoryState>(
                   initialize: { _, _ in HistoryState(done: .empty, undone: .empty, prevRanges: nil, prevTime: 0, prevComposition: -1) },
                   apply: { tr, hist, state, _ in applyTransaction(hist, state, tr, options) }),
               extra: ["historyConfig": options])
    }

    /// Stop the next change from being grouped with the previous one.
    @discardableResult
    public static func closeHistory(_ tr: Transaction) -> Transaction { tr.setMeta(closeKey, true) }

    public static let undo: Command = buildCommand(redo: false, scroll: true)
    public static let redo: Command = buildCommand(redo: true, scroll: true)
    public static let undoNoScroll: Command = buildCommand(redo: false, scroll: false)
    public static let redoNoScroll: Command = buildCommand(redo: true, scroll: false)

    /// The number of undoable events.
    public static func undoDepth(_ state: EditorState) -> Int { key.getState(state)?.done.eventCount ?? 0 }
    /// The number of redoable events.
    public static func redoDepth(_ state: EditorState) -> Int { key.getState(state)?.undone.eventCount ?? 0 }

    /// The action name of the event ``undo`` would revert, such as "Typing", or nil when it has none.
    public static func undoActionName(_ state: EditorState) -> String? { key.getState(state)?.done.lastEventName }
    /// The action name of the event ``redo`` would reapply, or nil when it has none.
    public static func redoActionName(_ state: EditorState) -> String? { key.getState(state)?.undone.lastEventName }

    /// Whether the transaction was created by undo or redo.
    public static func isHistoryTransaction(_ tr: Transaction) -> Bool { tr.getMeta(key) != nil }

    private static func buildCommand(redo: Bool, scroll: Bool) -> Command {
        return { state, dispatch, _ in
            guard let hist = key.getState(state), (redo ? hist.undone : hist.done).eventCount > 0 else { return false }
            if let dispatch, let tr = histTransaction(hist, state, redo) { dispatch(scroll ? tr.scrollIntoView() : tr) }
            return true
        }
    }

    static func applyTransaction(_ history: HistoryState, _ state: EditorState, _ tr: Transaction, _ options: HistoryOptions) -> HistoryState {
        var history = history
        if let meta = tr.getMeta(key, as: HistoryMeta.self) { return meta.historyState }
        if tr.getMeta(closeKey) != nil {
            history = HistoryState(done: history.done, undone: history.undone, prevRanges: nil, prevTime: 0, prevComposition: -1)
        }
        let appended = tr.getMeta("appendedTransaction", as: Transaction.self)
        let preserve = mustPreserveItems(state)
        if tr.steps.isEmpty {
            return history
        } else if let appendedMeta = appended?.getMeta(key, as: HistoryMeta.self) {
            if appendedMeta.redo {
                return HistoryState(done: history.done.addTransform(tr, nil, options, preserve), undone: history.undone,
                                    prevRanges: rangesFor(tr.mapping.maps), prevTime: history.prevTime,
                                    prevComposition: history.prevComposition)
            }
            return HistoryState(done: history.done, undone: history.undone.addTransform(tr, nil, options, preserve),
                                prevRanges: nil, prevTime: history.prevTime, prevComposition: history.prevComposition)
        } else if tr.getMeta("addToHistory") as? Bool != false && !(appended?.getMeta("addToHistory") as? Bool == false) {
            let composition = tr.getMeta("composition") as? Int
            let newGroup = history.prevTime == 0 ||
                (appended == nil && history.prevComposition != (composition ?? Int.min) &&
                 (history.prevTime < tr.time - options.newGroupDelay || !isAdjacentTo(tr, history.prevRanges)))
            let prevRanges = appended != nil ? mapRanges(history.prevRanges, tr.mapping) : rangesFor(tr.mapping.maps)
            return HistoryState(done: history.done.addTransform(tr, newGroup ? state.selection.getBookmark() : nil, options, preserve,
                                                                name: tr.actionName ?? appended?.actionName),
                                undone: .empty, prevRanges: prevRanges, prevTime: tr.time,
                                prevComposition: composition ?? history.prevComposition)
        } else if let rebased = tr.getMeta("rebased") as? Int {
            return HistoryState(done: history.done.rebased(tr, rebased), undone: history.undone.rebased(tr, rebased),
                                prevRanges: mapRanges(history.prevRanges, tr.mapping), prevTime: history.prevTime,
                                prevComposition: history.prevComposition)
        } else {
            return HistoryState(done: history.done.addMaps(tr.mapping.maps), undone: history.undone.addMaps(tr.mapping.maps),
                                prevRanges: mapRanges(history.prevRanges, tr.mapping), prevTime: history.prevTime,
                                prevComposition: history.prevComposition)
        }
    }

    static func isAdjacentTo(_ transform: Transform, _ prevRanges: [Int]?) -> Bool {
        guard let prevRanges else { return false }
        if !transform.docChanged { return true }
        var adjacent = false
        transform.mapping.maps[0].forEach { start, end, _, _ in
            var i = 0
            while i < prevRanges.count {
                if start <= prevRanges[i + 1] && end >= prevRanges[i] { adjacent = true }
                i += 2
            }
        }
        return adjacent
    }

    static func rangesFor(_ maps: [StepMap]) -> [Int] {
        var result: [Int] = []
        var i = maps.count - 1
        while i >= 0 && result.isEmpty {
            maps[i].forEach { _, _, from, to in result.append(from); result.append(to) }
            i -= 1
        }
        return result
    }

    static func mapRanges(_ ranges: [Int]?, _ mapping: Mapping) -> [Int]? {
        guard let ranges else { return nil }
        var result: [Int] = []
        var i = 0
        while i < ranges.count {
            let from = mapping.map(ranges[i], assoc: 1), to = mapping.map(ranges[i + 1], assoc: -1)
            if from <= to { result.append(from); result.append(to) }
            i += 2
        }
        return result
    }

    static func selectionFromChanges(_ state: EditorState, _ tr: Transaction) -> Selection {
        for i in 0..<tr.steps.count {
            var pos = -1
            tr.mapping.maps[i].forEach { _, end, _, _ in pos = end }
            if pos < 0 {
                if let s = tr.steps[i] as? AddMarkStep { pos = s.to } else if let s = tr.steps[i] as? RemoveMarkStep { pos = s.to }
            }
            if pos > -1 { return Selection.near(state.doc.resolve(pos)) }
        }
        return state.selection
    }

    static func histTransaction(_ history: HistoryState, _ state: EditorState, _ redo: Bool) -> Transaction? {
        let preserve = mustPreserveItems(state)
        let options = key.get(state)?.extra["historyConfig"] as? HistoryOptions ?? .init()
        guard let pop = (redo ? history.undone : history.done).popEvent(state, preserve) else { return nil }
        let selection = pop.selection.resolve(pop.transform.doc)
        let added = (redo ? history.done : history.undone).addTransform(
            pop.transform, selectionFromChanges(state, pop.transform).getBookmark(), options, preserve, name: pop.name)
        let newHist = HistoryState(done: redo ? added : pop.remaining, undone: redo ? pop.remaining : added,
                                   prevRanges: nil, prevTime: 0, prevComposition: -1)
        return pop.transform.setSelection(selection).setMeta(key, HistoryMeta(redo: redo, historyState: newHist))
    }

    static func mustPreserveItems(_ state: EditorState) -> Bool {
        state.plugins.contains { $0.extra["historyPreserveItems"] as? Bool == true }
    }
}
