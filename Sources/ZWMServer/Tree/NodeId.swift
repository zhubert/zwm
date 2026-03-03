import Foundation

public struct NodeId: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "node-\(rawValue)" }
}

public struct NodeIdGenerator: Sendable, Equatable {
    private var next: UInt64

    public init(startingAt value: UInt64 = 1) {
        self.next = value
    }

    public mutating func generate() -> NodeId {
        let id = NodeId(rawValue: next)
        next += 1
        return id
    }
}
