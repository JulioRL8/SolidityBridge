import Foundation

public enum WalletError: Error, Equatable, Sendable {
    case invalidPublicKey
    case accountMismatch
    case transactionReverted(TransactionHash)
}

public enum TransactionState: Sendable {
    case awaitingApproval
    case pending(TransactionHash)
    case confirmed(TransactionReceipt)
    case failed(hash: TransactionHash?, error: any Error)
}

/// A session for the selected account. The implementation routes eth_sendTransaction to the given chain.
public protocol ExternalWalletSession: Sendable {
    func sendTransaction(_ request: WalletTransactionRequest, chainID: UInt64) async throws -> TransactionHash
}

/// Parameters of eth_sendTransaction, encoded as Ethereum JSON-RPC quantities.
public struct WalletTransactionRequest: Sendable, Encodable {
    public let transaction: EIP1559Transaction

    private enum CodingKeys: String, CodingKey {
        case from, to, data, value, gas, nonce, maxFeePerGas, maxPriorityFeePerGas, type
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transaction.from, forKey: .from)
        try container.encodeIfPresent(transaction.to, forKey: .to)
        try container.encode(transaction.data.ethereumHex, forKey: .data)
        try container.encode(transaction.value.hex, forKey: .value)
        try container.encode(UInt256(transaction.gasLimit).hex, forKey: .gas)
        try container.encode(UInt256(transaction.nonce).hex, forKey: .nonce)
        try container.encode(transaction.maxFeePerGas.hex, forKey: .maxFeePerGas)
        try container.encode(transaction.maxPriorityFeePerGas.hex, forKey: .maxPriorityFeePerGas)
        try container.encode("0x2", forKey: .type)
    }
}

public struct ExternalWallet: Sendable {
    public let address: EthereumAddress
    private let session: any ExternalWalletSession

    public init(address: EthereumAddress, session: any ExternalWalletSession) {
        self.address = address
        self.session = session
    }

    func send(_ transaction: EIP1559Transaction) async throws -> TransactionHash {
        guard transaction.from == address else { throw WalletError.accountMismatch }
        try Task.checkCancellation()
        return try await session.sendTransaction(WalletTransactionRequest(transaction: transaction), chainID: transaction.chainID)
    }
}

extension EthereumContract {
    public func send(
        _ function: String,
        arguments: [ABIValue] = [],
        wallet: ExternalWallet,
        options: TransactionOptions = .init()
    ) async throws -> TransactionHash {
        try await submit(function, arguments: arguments, from: wallet.address, options: options, using: wallet.send)
    }

    public func execute(
        _ function: String,
        arguments: [ABIValue] = [],
        signer: any EthereumSigner,
        options: TransactionOptions = .init(),
        confirmations: UInt64 = 1,
        onState: @Sendable (TransactionState) async -> Void
    ) async throws -> TransactionReceipt {
        try await client.track(confirmations: confirmations, onState: onState) {
            try await submit(function, arguments: arguments, from: signer.address, options: options) { transaction in
                await onState(.awaitingApproval)
                try Task.checkCancellation()
                let signature = try await signer.sign(transaction: transaction)
                return try await client.broadcast(transaction, signature: signature)
            }
        }
    }

    public func execute(
        _ function: String,
        arguments: [ABIValue] = [],
        wallet: ExternalWallet,
        options: TransactionOptions = .init(),
        confirmations: UInt64 = 1,
        onState: @Sendable (TransactionState) async -> Void
    ) async throws -> TransactionReceipt {
        try await client.track(confirmations: confirmations, onState: onState) {
            try await submit(function, arguments: arguments, from: wallet.address, options: options) { transaction in
                await onState(.awaitingApproval)
                return try await wallet.send(transaction)
            }
        }
    }

    func submit(
        _ function: String,
        arguments: [ABIValue],
        from: EthereumAddress,
        options: TransactionOptions,
        using send: @Sendable (EIP1559Transaction) async throws -> TransactionHash
    ) async throws -> TransactionHash {
        try await client.submit(from: from) {
            let transaction = try await prepareTransaction(function, arguments: arguments, from: from, options: options)
            try Task.checkCancellation()
            return try await send(transaction)
        }
    }
}

extension EthereumClient {
    func track(
        confirmations: UInt64,
        onState: @Sendable (TransactionState) async -> Void,
        submit: () async throws -> TransactionHash
    ) async throws -> TransactionReceipt {
        var hash: TransactionHash?
        do {
            guard confirmations > 0 else { throw ReceiptWaitError.invalidConfirmationCount }
            let submitted = try await submit()
            hash = submitted
            await onState(.pending(submitted))
            let receipt = try await waitForReceipt(for: submitted, confirmations: confirmations)
            guard receipt.succeeded else { throw WalletError.transactionReverted(submitted) }
            await onState(.confirmed(receipt))
            return receipt
        } catch {
            let knownHash = hash ?? (error as? TransactionBroadcastError)?.hash
            await onState(.failed(hash: knownHash, error: error))
            throw error
        }
    }
}
