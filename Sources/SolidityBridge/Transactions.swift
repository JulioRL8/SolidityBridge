import Foundation

public struct TransactionOptions: Sendable {
    public let value: UInt256
    public let gasLimit: UInt64?
    public let maxFeePerGas: UInt256?
    public let maxPriorityFeePerGas: UInt256?

    public init(
        value: UInt256 = UInt256(0),
        gasLimit: UInt64? = nil,
        maxFeePerGas: UInt256? = nil,
        maxPriorityFeePerGas: UInt256? = nil
    ) {
        self.value = value
        self.gasLimit = gasLimit
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
    }
}

/// The signer uses the account corresponding to `address` and signs the transaction digest as-is.
public protocol EthereumSigner: Sendable {
    var address: EthereumAddress { get }
    func sign(transaction: EIP1559Transaction) async throws -> EthereumSignature
}

public struct EthereumSignature: Sendable {
    public let yParity: UInt8
    public let r: UInt256
    public let s: UInt256

    private static let curveOrder = Data([
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41
    ])
    private static let halfCurveOrder = Data([
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0
    ])

    public init(yParity: UInt8, r: UInt256, s: UInt256) throws {
        guard yParity <= 1, r > UInt256(0), r.bytes.lexicographicallyPrecedes(Self.curveOrder),
              s > UInt256(0), !Self.halfCurveOrder.lexicographicallyPrecedes(s.bytes) else {
            throw SolidityBridgeError.invalidSignature
        }
        self.yParity = yParity
        self.r = r
        self.s = s
    }

    /// Reads `r || s || v`, accepting recovery IDs 0/1 or 27/28.
    public init(compact bytes: Data) throws {
        let bytes = Data(bytes)
        guard bytes.count == 65 else { throw SolidityBridgeError.invalidSignature }
        let recovery = bytes[64]
        try self.init(
            yParity: recovery >= 27 ? recovery - 27 : recovery,
            r: UInt256(word: bytes.prefix(32)),
            s: UInt256(word: bytes[32..<64])
        )
    }
}

public struct EIP1559Transaction: Sendable {
    public let chainID: UInt64
    public let nonce: UInt64
    public let from: EthereumAddress
    public let to: EthereumAddress?
    public let value: UInt256
    public let data: Data
    public let gasLimit: UInt64
    public let maxFeePerGas: UInt256
    public let maxPriorityFeePerGas: UInt256

    /// Ethereum typed payload to hash with Keccak-256 for signing.
    public var signingPayload: Data { Data([2]) + RLP.list(fields) }

    public var signingDigest: Data { Keccak256.hash(signingPayload) }

    func signed(with signature: EthereumSignature) -> Data {
        Data([2]) + RLP.list(fields + [
            RLP.integer(UInt256(UInt64(signature.yParity))),
            RLP.integer(signature.r),
            RLP.integer(signature.s)
        ])
    }

    private var fields: [Data] {
        [
            RLP.integer(UInt256(chainID)),
            RLP.integer(UInt256(nonce)),
            RLP.integer(maxPriorityFeePerGas),
            RLP.integer(maxFeePerGas),
            RLP.integer(UInt256(gasLimit)),
            RLP.bytes(to?.bytes ?? Data()),
            RLP.integer(value),
            RLP.bytes(data),
            RLP.list([])
        ]
    }
}

private enum RLP {
    static func integer(_ value: UInt256) -> Data {
        bytes(Data(value.bytes.drop(while: { $0 == 0 })))
    }

    static func bytes(_ bytes: Data) -> Data {
        if bytes.count == 1, let byte = bytes.first, byte < 0x80 {
            return bytes
        }
        return prefix(length: bytes.count, offset: 0x80) + bytes
    }

    static func list(_ items: [Data]) -> Data {
        var body = Data()
        for item in items { body.append(item) }
        return prefix(length: body.count, offset: 0xc0) + body
    }

    private static func prefix(length: Int, offset: UInt8) -> Data {
        if length < 56 { return Data([offset + UInt8(length)]) }
        let bytes = Data(UInt256(UInt64(length)).bytes.drop(while: { $0 == 0 }))
        return Data([offset + 55 + UInt8(bytes.count)]) + bytes
    }
}

public struct EthereumLog: Decodable, Equatable, Sendable {
    public let address: EthereumAddress
    public let topics: [Hash32]
    public let data: Data
    public let transactionHash: TransactionHash?
    public let blockNumber: UInt64?
    public let blockHash: Hash32?
    public let logIndex: UInt64?
    public let removed: Bool

    private enum CodingKeys: String, CodingKey {
        case address, topics, data, transactionHash, blockNumber, blockHash, logIndex, removed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(EthereumAddress.self, forKey: .address)
        topics = try container.decode([Hash32].self, forKey: .topics)
        data = try Data(ethereumHex: container.decode(String.self, forKey: .data))
        transactionHash = try container.decodeIfPresent(TransactionHash.self, forKey: .transactionHash)
        blockNumber = try container.decodeIfPresent(RPCQuantity.self, forKey: .blockNumber)?.asUInt64()
        blockHash = try container.decodeIfPresent(Hash32.self, forKey: .blockHash)
        logIndex = try container.decodeIfPresent(RPCQuantity.self, forKey: .logIndex)?.asUInt64()
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }
}

public struct TransactionReceipt: Decodable, Equatable, Sendable {
    public let transactionHash: TransactionHash
    public let blockNumber: UInt64
    public let blockHash: Hash32
    public let contractAddress: EthereumAddress?
    public let gasUsed: UInt64
    public let succeeded: Bool
    public let logs: [EthereumLog]

    private enum CodingKeys: String, CodingKey {
        case transactionHash, blockNumber, blockHash, contractAddress, gasUsed, status, logs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionHash = try container.decode(TransactionHash.self, forKey: .transactionHash)
        blockNumber = try container.decode(RPCQuantity.self, forKey: .blockNumber).asUInt64()
        blockHash = try container.decode(Hash32.self, forKey: .blockHash)
        contractAddress = try container.decodeIfPresent(EthereumAddress.self, forKey: .contractAddress)
        gasUsed = try container.decode(RPCQuantity.self, forKey: .gasUsed).asUInt64()
        let status = try container.decode(RPCQuantity.self, forKey: .status).asUInt64()
        guard status <= 1 else { throw SolidityBridgeError.invalidRPCResponse }
        succeeded = status == 1
        logs = try container.decode([EthereumLog].self, forKey: .logs)
    }
}
