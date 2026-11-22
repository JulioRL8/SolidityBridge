import Foundation

public struct EthereumClient: Sendable {
    public let chainID: UInt64
    let rpc: JSONRPC
    private let submissions = TransactionSubmissions()

    public init(chainID: UInt64, rpcURL: URL, headers: [String: String] = [:]) throws {
        self.init(chainID: chainID, transport: try HTTPTransport(endpoint: rpcURL, headers: headers))
    }

    public init(chainID: UInt64, transport: any RPCTransport) {
        self.chainID = chainID
        rpc = JSONRPC(transport: transport)
    }

    public func contract(at address: EthereumAddress, abi: ContractABI) -> EthereumContract {
        EthereumContract(address: address, abi: abi, client: self)
    }

    public func verifyChain() async throws {
        let chain: RPCQuantity = try await rpc.request("eth_chainId")
        let actual = try chain.asUInt64()
        guard actual == chainID else { throw SolidityBridgeError.wrongChain(expected: chainID, actual: actual) }
    }

    public func blockNumber() async throws -> UInt64 {
        let head: RPCQuantity = try await rpc.request("eth_blockNumber")
        return try head.asUInt64()
    }

    /// Returns nil until the node has a mined receipt.
    public func receipt(for hash: TransactionHash) async throws -> TransactionReceipt? {
        let result: TransactionReceipt? = try await rpc.request(
            "eth_getTransactionReceipt", params: [.string(hash.description)]
        )
        if let result, result.transactionHash != hash {
            throw SolidityBridgeError.invalidRPCResponse
        }
        return result
    }

    /// Waits for inclusion in a block. The receipt reports whether execution succeeded.
    public func waitForReceipt(
        for hash: TransactionHash,
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .seconds(2),
        confirmations: UInt64 = 1
    ) async throws -> TransactionReceipt {
        guard timeout > .zero, pollInterval > .zero else { throw ReceiptWaitError.invalidDuration }
        guard confirmations > 0 else { throw ReceiptWaitError.invalidConfirmationCount }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let receipt = try await receipt(for: hash) {
                if confirmations == 1 { return receipt }
                let head = try await blockNumber()
                if head >= receipt.blockNumber, head - receipt.blockNumber >= confirmations - 1,
                   try await canonicalBlockHash(at: receipt.blockNumber) == receipt.blockHash {
                    return receipt
                }
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: pollInterval)))
        }
        throw ReceiptWaitError.timedOut(hash)
    }

    func canonicalBlockHash(at height: UInt64) async throws -> Hash32? {
        struct Block: Decodable { let hash: Hash32 }
        let block: Block? = try await rpc.request(
            "eth_getBlockByNumber", params: [.string(BlockTag.number(height).rpcValue), .bool(false)]
        )
        return block?.hash
    }

    func prepare(
        call: RPCCall, calldata: Data, from: EthereumAddress, options: TransactionOptions
    ) async throws -> EIP1559Transaction {
        try await verifyChain()
        let nonce: RPCQuantity = try await rpc.request(
            "eth_getTransactionCount", params: [.string(from.bytes.ethereumHex), .string("pending")]
        )
        let fees = try await transactionFees(options)
        var call = call
        call.maxFeePerGas = fees.maximum.hex
        call.maxPriorityFeePerGas = fees.priority.hex
        let gasLimit: UInt64
        if let explicitLimit = options.gasLimit {
            gasLimit = explicitLimit
        } else {
            let estimate: RPCQuantity = try await rpc.request("eth_estimateGas", params: [.call(call)])
            gasLimit = try estimate.asUInt64()
        }

        return EIP1559Transaction(
            chainID: chainID, nonce: try nonce.asUInt64(), from: from, to: call.to,
            value: options.value, data: calldata, gasLimit: gasLimit,
            maxFeePerGas: fees.maximum, maxPriorityFeePerGas: fees.priority
        )
    }

    func submit(
        from address: EthereumAddress,
        operation: @Sendable () async throws -> TransactionHash
    ) async throws -> TransactionHash {
        try await submissions.run(from: address, operation: operation)
    }

    func broadcast(_ transaction: EIP1559Transaction, signature: EthereumSignature) async throws -> TransactionHash {
        try Task.checkCancellation()
        let signed = transaction.signed(with: signature)
        let hash = TransactionHash(bytes: Keccak256.hash(signed))
        let returned: TransactionHash
        do {
            returned = try await rpc.request("eth_sendRawTransaction", params: [.string(signed.ethereumHex)])
        } catch {
            throw TransactionBroadcastError(hash: hash, underlyingError: error)
        }
        guard returned == hash else {
            throw TransactionBroadcastError(
                hash: hash, underlyingError: SolidityBridgeError.unexpectedTransactionHash(expected: hash)
            )
        }
        return hash
    }

    private func transactionFees(
        _ options: TransactionOptions
    ) async throws -> (maximum: UInt256, priority: UInt256) {
        let priority: UInt256
        if let configuredPriority = options.maxPriorityFeePerGas {
            priority = configuredPriority
        } else {
            let suggested: RPCQuantity = try await rpc.request("eth_maxPriorityFeePerGas")
            priority = suggested.value
        }

        let maximum: UInt256
        if let configuredMaximum = options.maxFeePerGas {
            maximum = configuredMaximum
        } else {
            let latest: FeeBlock = try await rpc.request(
                "eth_getBlockByNumber", params: [.string("latest"), .bool(false)]
            )
            guard let base = latest.baseFeePerGas?.value else { throw SolidityBridgeError.invalidFees }
            maximum = try base.adding(base).adding(priority)
        }
        guard maximum >= priority else { throw SolidityBridgeError.invalidFees }
        return (maximum, priority)
    }

    private struct FeeBlock: Decodable {
        let baseFeePerGas: RPCQuantity?
    }
}

public enum ReceiptWaitError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidConfirmationCount
    case timedOut(TransactionHash)
}

/// A broadcast failed or its outcome is unknown. The hash is derived locally from the signed transaction.
public struct TransactionBroadcastError: Error, Sendable {
    public let hash: TransactionHash
    public let underlyingError: any Error
}

private actor TransactionSubmissions {
    private var active: Set<EthereumAddress> = []

    func run(
        from address: EthereumAddress,
        operation: @Sendable () async throws -> TransactionHash
    ) async throws -> TransactionHash {
        try Task.checkCancellation()
        guard active.insert(address).inserted else { throw SolidityBridgeError.conflictingSubmission(address) }
        defer { active.remove(address) }
        return try await operation()
    }
}
