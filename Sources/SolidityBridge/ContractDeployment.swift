import Foundation

public enum ContractDeploymentError: Error, Equatable, Sendable {
    case missingBytecode
    case invalidBytecode
    case nonPayableConstructor
}

/// Creation bytecode and ABI from a compiled Solidity contract.
public struct ContractArtifact: Sendable {
    public let abi: ContractABI
    public let bytecode: Data

    /// Foundry stores bytecode in bytecode.object. Hardhat stores it directly in bytecode.
    public init(json: Data) throws {
        let artifact = try JSONDecoder().decode(BytecodeEntry.self, from: json)
        guard let hex = artifact.bytecode else { throw ContractDeploymentError.missingBytecode }
        guard let code = try? Data(ethereumHex: hex) else { throw ContractDeploymentError.invalidBytecode }
        guard !code.isEmpty else { throw ContractDeploymentError.missingBytecode }
        abi = try ContractABI(json: json)
        bytecode = code
    }

    private struct BytecodeEntry: Decodable {
        let bytecode: String?

        private enum CodingKeys: String, CodingKey { case bytecode }
        private struct FoundryBytecode: Decodable { let object: String }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let hex = try? container.decode(String.self, forKey: .bytecode) {
                bytecode = hex
            } else {
                bytecode = try container.decodeIfPresent(FoundryBytecode.self, forKey: .bytecode)?.object
            }
        }
    }
}

extension EthereumClient {
    public func prepareDeployment(
        _ artifact: ContractArtifact,
        arguments: [ABIValue] = [],
        from: EthereumAddress,
        options: TransactionOptions = .init()
    ) async throws -> EIP1559Transaction {
        let constructor = artifact.abi.constructor
        guard options.value == UInt256(0) || constructor?.payable == true else {
            throw ContractDeploymentError.nonPayableConstructor
        }
        let data = try artifact.bytecode + ABICodec.encode(constructor?.inputs ?? [], values: arguments)
        let call = RPCCall(from: from, to: nil, data: data.ethereumHex, value: options.value.hex)
        return try await prepare(call: call, calldata: data, from: from, options: options)
    }

    public func deploy(
        _ artifact: ContractArtifact,
        arguments: [ABIValue] = [],
        signer: any EthereumSigner,
        options: TransactionOptions = .init()
    ) async throws -> TransactionHash {
        try await submit(from: signer.address) {
            let transaction = try await prepareDeployment(artifact, arguments: arguments, from: signer.address, options: options)
            try Task.checkCancellation()
            let signature = try await signer.sign(transaction: transaction)
            return try await broadcast(transaction, signature: signature)
        }
    }

    public func deploy(
        _ artifact: ContractArtifact,
        arguments: [ABIValue] = [],
        wallet: ExternalWallet,
        options: TransactionOptions = .init()
    ) async throws -> TransactionHash {
        try await submit(from: wallet.address) {
            let transaction = try await prepareDeployment(artifact, arguments: arguments, from: wallet.address, options: options)
            return try await wallet.send(transaction)
        }
    }
}
