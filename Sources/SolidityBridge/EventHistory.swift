import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ContractEventPage: Sendable {
    public let blocks: ClosedRange<UInt64>
    public let events: [ContractEvent]
}

public struct EventPages: AsyncSequence, Sendable {
    let blocks: ClosedRange<UInt64>
    let pageSize: UInt64
    let fetch: @Sendable (ClosedRange<UInt64>) async throws -> [ContractEvent]

    public func makeAsyncIterator() -> Iterator {
        Iterator(source: self, nextBlock: blocks.lowerBound)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let source: EventPages
        var nextBlock: UInt64?

        public mutating func next() async throws -> ContractEventPage? {
            try Task.checkCancellation()
            guard let start = nextBlock else { return nil }
            let end = start + Swift.min(source.blocks.upperBound - start, source.pageSize - 1)
            let range = start...end
            let events = try await source.fetch(range)
            nextBlock = end == source.blocks.upperBound ? nil : end + 1
            return ContractEventPage(blocks: range, events: events)
        }
    }
}

public struct EventWatchOptions: Sendable {
    public let pageSize: UInt64
    public let confirmations: UInt64
    public let pollInterval: Duration
    public let reconnectAttempts: Int

    public init(
        pageSize: UInt64 = 1_000,
        confirmations: UInt64 = 1,
        pollInterval: Duration = .seconds(3),
        reconnectAttempts: Int = 5
    ) {
        self.pageSize = pageSize
        self.confirmations = confirmations
        self.pollInterval = pollInterval
        self.reconnectAttempts = max(0, reconnectAttempts)
    }
}

public struct EventWatch: AsyncSequence, Sendable {
    let firstBlock: UInt64
    let options: EventWatchOptions
    let head: @Sendable () async throws -> UInt64
    let blockHash: @Sendable (UInt64) async throws -> Hash32?
    let fetch: @Sendable (ClosedRange<UInt64>) async throws -> [ContractEvent]

    public func makeAsyncIterator() -> Iterator {
        Iterator(source: self, nextBlock: firstBlock)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let source: EventWatch
        var nextBlock: UInt64?
        var checkpoint: (block: UInt64, hash: Hash32)?

        public mutating func next() async throws -> ContractEventPage? {
            guard let start = nextBlock else { return nil }
            let options = source.options
            let depth = options.confirmations - 1
            var failures = 0
            while true {
                try Task.checkCancellation()
                do {
                    if let checkpoint,
                       try await source.blockHash(checkpoint.block) != checkpoint.hash {
                        throw EventQueryError.reorganizationDetected(lastDeliveredBlock: checkpoint.block)
                    }
                    let head = try await source.head()
                    if head >= depth, head - depth >= start {
                        let end = start + Swift.min(head - depth - start, options.pageSize - 1)
                        let range = start...end
                        if let hash = try await source.blockHash(end) {
                            let events = try await source.fetch(range)
                            if try await source.blockHash(end) == hash {
                                checkpoint = (end, hash)
                                nextBlock = end == UInt64.max ? nil : end + 1
                                return ContractEventPage(blocks: range, events: events)
                            }
                        }
                    }
                    failures = 0
                } catch {
                    guard failures < options.reconnectAttempts, Self.isTransient(error) else { throw error }
                    failures += 1
                }
                try await ContinuousClock().sleep(for: options.pollInterval)
            }
        }

        private static func isTransient(_ error: any Error) -> Bool {
            if let error = error as? URLError {
                return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                        .networkConnectionLost, .notConnectedToInternet].contains(error.code)
            }
            if case SolidityBridgeError.httpStatus(let status) = error {
                return status == 429 || (500...599).contains(status)
            }
            return false
        }
    }
}
