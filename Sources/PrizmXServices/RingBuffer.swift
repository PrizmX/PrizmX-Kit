import Foundation

/// Fixed-capacity circular buffer. Oldest elements are overwritten first
/// once `capacity` is reached.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int

    private var storage: [Element]
    private var head: Int
    public private(set) var count: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = []
        self.storage.reserveCapacity(capacity)
        self.head = 0
        self.count = 0
    }

    public init(capacity: Int, elements: [Element]) {
        self.init(capacity: capacity)
        for element in elements.suffix(capacity) {
            append(element)
        }
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == capacity }

    /// Chronological contents, oldest first.
    public var elements: [Element] {
        if count == 0 { return [] }
        if count < capacity { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    public mutating func append(_ element: Element) {
        if count < capacity {
            storage.append(element)
            count += 1
            return
        }
        storage[head] = element
        head = (head + 1) % capacity
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }
}
