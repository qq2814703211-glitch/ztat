// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Lightweight OrderedSet shim replacing apple/swift-collections dependency for TrayDrop.

import Foundation

struct OrderedSet<Element: Hashable>: RandomAccessCollection, Equatable, Hashable, ExpressibleByArrayLiteral {
    private var storage: [Element] = []
    private var membership: Set<Element> = []

    init() {}

    init<S: Sequence>(_ elements: S) where S.Element == Element {
        for element in elements {
            append(element)
        }
    }

    init(arrayLiteral elements: Element...) {
        self.init(elements)
    }

    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }

    subscript(position: Int) -> Element {
        storage[position]
    }

    var elements: [Element] { storage }

    @discardableResult
    mutating func append(_ element: Element) -> (inserted: Bool, index: Int) {
        if let existing = storage.firstIndex(of: element) {
            return (false, existing)
        }
        membership.insert(element)
        storage.append(element)
        return (true, storage.count - 1)
    }

    @discardableResult
    mutating func updateOrInsert(_ element: Element, at index: Int) -> (inserted: Bool, index: Int) {
        if let existing = storage.firstIndex(of: element) {
            storage.remove(at: existing)
            let clamped = Swift.max(0, Swift.min(index, storage.count))
            storage.insert(element, at: clamped)
            return (false, clamped)
        }
        membership.insert(element)
        let clamped = Swift.max(0, Swift.min(index, storage.count))
        storage.insert(element, at: clamped)
        return (true, clamped)
    }

    @discardableResult
    mutating func remove(_ element: Element) -> Element? {
        guard membership.remove(element) != nil,
              let idx = storage.firstIndex(of: element) else {
            return nil
        }
        return storage.remove(at: idx)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        membership.removeAll(keepingCapacity: keepingCapacity)
    }

    func contains(_ element: Element) -> Bool {
        membership.contains(element)
    }

    static func == (lhs: OrderedSet<Element>, rhs: OrderedSet<Element>) -> Bool {
        lhs.storage == rhs.storage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}
