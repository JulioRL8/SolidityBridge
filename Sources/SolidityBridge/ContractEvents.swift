import Foundation

public struct ContractEvent: Equatable, Sendable {
    public struct Argument: Equatable, Sendable {
        public enum Value: Equatable, Sendable {
            case decoded(ABIValue)
            /// Solidity stores only the hash of an indexed array, tuple, string or dynamic bytes.
            case indexedHash(Hash32)
        }

        public let name: String
        public let indexed: Bool
        public let value: Value
    }

    public let signature: String
    public let arguments: [Argument]
    public let log: EthereumLog
}

public enum EventTopic: Sendable {
    case value(ABIValue)
    case hash(Hash32)
}

public enum EventTopicFilter: Sendable {
    case any
    case one(EventTopic)
    case anyOf([EventTopic])
}

public enum EventQueryError: Error, Equatable, Sendable {
    case invalidTopicFilters
    case invalidPageSize
    case invalidSubscriptionOptions
    case reorganizationDetected(lastDeliveredBlock: UInt64)
}

extension EthereumContract {
    /// Filters indexed arguments in declaration order. Use .any to skip an earlier argument.
    public func logs(
        _ event: String,
        from firstBlock: BlockTag,
        to lastBlock: BlockTag = .latest,
        indexed: [EventTopicFilter] = []
    ) async throws -> [ContractEvent] {
        let declaration = try abi.event(event)
        let topics = try makeTopics(declaration, indexed: indexed)
        return try await fetchEvents(declaration, from: firstBlock, to: lastBlock, topics: topics)
    }

    /// Iterates over bounded block ranges, including empty pages.
    public func logPages(
        _ event: String,
        blocks: ClosedRange<UInt64>,
        pageSize: UInt64 = 1_000,
        indexed: [EventTopicFilter] = []
    ) throws -> EventPages {
        guard pageSize > 0 else { throw EventQueryError.invalidPageSize }
        let declaration = try abi.event(event)
        let topics = try makeTopics(declaration, indexed: indexed)
        return EventPages(blocks: blocks, pageSize: pageSize) { range in
            try await fetchEvents(declaration, from: .number(range.lowerBound), to: .number(range.upperBound), topics: topics)
        }
    }

    /// Watches confirmed block ranges over HTTP. The iterator retries the same range after a connection loss.
    public func watchLogs(
        _ event: String,
        from firstBlock: UInt64,
        indexed: [EventTopicFilter] = [],
        options: EventWatchOptions = .init()
    ) throws -> EventWatch {
        guard options.pageSize > 0, options.confirmations > 0, options.pollInterval > .zero else {
            throw EventQueryError.invalidSubscriptionOptions
        }
        let declaration = try abi.event(event)
        let topics = try makeTopics(declaration, indexed: indexed)
        return EventWatch(
            firstBlock: firstBlock, options: options,
            head: { try await client.blockNumber() },
            blockHash: { try await client.canonicalBlockHash(at: $0) }
        ) { range in
            try await fetchEvents(declaration, from: .number(range.lowerBound), to: .number(range.upperBound), topics: topics)
        }
    }

    private func makeTopics(_ event: ABIEvent, indexed: [EventTopicFilter]) throws -> [RPCLogTopic] {
        guard !event.anonymous else { throw SolidityBridgeError.anonymousEventFilter(event.signature) }
        let fields = event.fields.filter(\.indexed)
        guard indexed.count <= fields.count else { throw EventQueryError.invalidTopicFilters }
        return try [.one(event.topic)] + zip(fields, indexed).map { field, filter in
            func topic(_ value: EventTopic) throws -> Hash32 {
                switch value {
                case .value(let value): try ABICodec.indexedTopic(value, as: field.type)
                case .hash(let hash): hash
                }
            }
            switch filter {
            case .any: return .any
            case .one(let value): return .one(try topic(value))
            case .anyOf(let values):
                guard !values.isEmpty else { throw EventQueryError.invalidTopicFilters }
                return .alternatives(try values.map(topic))
            }
        }
    }

    private func fetchEvents(
        _ event: ABIEvent, from: BlockTag, to: BlockTag, topics: [RPCLogTopic]
    ) async throws -> [ContractEvent] {
        let filter = RPCLogFilter(address: address, fromBlock: from.rpcValue, toBlock: to.rpcValue, topics: topics)
        let logs: [EthereumLog] = try await client.rpc.request("eth_getLogs", params: [.logFilter(filter)])
        return try logs.map { try decode($0, as: event) }
    }

    /// Decodes a receipt log for a known ABI event.
    public func decodeLog(_ log: EthereumLog, as event: String) throws -> ContractEvent {
        try decode(log, as: abi.event(event))
    }

    private func decode(_ log: EthereumLog, as event: ABIEvent) throws -> ContractEvent {
        let signatureTopicCount = event.anonymous ? 0 : 1
        guard log.address == address, (event.anonymous || log.topics.first == event.topic),
              log.topics.count == signatureTopicCount + event.fields.filter(\.indexed).count else {
            throw SolidityBridgeError.unrelatedLog
        }

        let unindexed = event.fields.filter { !$0.indexed }.map(\.type)
        var decoded = try ABICodec.decode(unindexed, from: log.data).makeIterator()
        var topics = log.topics.dropFirst(signatureTopicCount).makeIterator()

        let arguments = try event.fields.map { field -> ContractEvent.Argument in
            let value: ContractEvent.Argument.Value
            if field.indexed, let topic = topics.next() {
                switch field.type {
                case .array, .tuple, .string, .bytes:
                    value = .indexedHash(topic)
                default:
                    guard let decoded = try ABICodec.decode([field.type], from: topic.bytes).first else {
                        throw SolidityBridgeError.malformedABIData
                    }
                    value = .decoded(decoded)
                }
            } else {
                guard let next = decoded.next() else { throw SolidityBridgeError.malformedABIData }
                value = .decoded(next)
            }
            return ContractEvent.Argument(name: field.name, indexed: field.indexed, value: value)
        }
        return ContractEvent(signature: event.signature, arguments: arguments, log: log)
    }
}

struct ABIEvent: Sendable {
    struct Field: Sendable {
        let name: String
        let type: ABIType
        let indexed: Bool
    }

    let name: String
    let fields: [Field]
    let anonymous: Bool

    var signature: String { abiSignature(name: name, inputs: fields.map(\.type)) }
    var topic: Hash32 { Hash32(bytes: Keccak256.hash(Data(signature.utf8))) }
}
