import Foundation

public struct ContractRevert: Error, Equatable, Sendable {
    public let rpcError: RPCError
    public let signature: String
    public let arguments: [ABIValue]
}

public struct EthereumContract: Sendable {
    public let address: EthereumAddress
    public let abi: ContractABI
    let client: EthereumClient

    /// Accepts a unique function name or a canonical signature for an overloaded function.
    public func read(
        _ function: String,
        arguments: [ABIValue] = [],
        from: EthereumAddress? = nil,
        at block: BlockTag = .latest
    ) async throws -> [ABIValue] {
        try await simulate(function, arguments: arguments, from: from, at: block)
    }

    /// Executes a call against a block without committing state changes.
    public func simulate(
        _ function: String,
        arguments: [ABIValue] = [],
        from: EthereumAddress? = nil,
        value: UInt256 = UInt256(0),
        at block: BlockTag = .latest
    ) async throws -> [ABIValue] {
        let declaration = try abi.function(function)
        let calldata = try declaration.calldata(arguments: arguments)
        let call = try makeCall(declaration, calldata: calldata, from: from, value: value)
        do {
            let result: String = try await client.rpc.request(
                "eth_call", params: [.call(call), .string(block.rpcValue)]
            )
            return try ABICodec.decode(declaration.outputs, from: Data(ethereumHex: result))
        } catch let error as RPCError {
            throw decodeRevert(error) ?? error
        }
    }

    public func estimateGas(
        _ function: String,
        arguments: [ABIValue] = [],
        from: EthereumAddress? = nil,
        value: UInt256 = UInt256(0)
    ) async throws -> UInt64 {
        let declaration = try abi.function(function)
        let calldata = try declaration.calldata(arguments: arguments)
        let call = try makeCall(declaration, calldata: calldata, from: from, value: value)
        do {
            let result: RPCQuantity = try await client.rpc.request("eth_estimateGas", params: [.call(call)])
            return try result.asUInt64()
        } catch let error as RPCError {
            throw decodeRevert(error) ?? error
        }
    }

    /// Prepares a transaction for inspection. The nonce is read from the node and is not reserved.
    public func prepareTransaction(
        _ function: String,
        arguments: [ABIValue] = [],
        from: EthereumAddress,
        options: TransactionOptions = .init()
    ) async throws -> EIP1559Transaction {
        let declaration = try abi.function(function)
        guard declaration.mutability == .payable || declaration.mutability == .nonpayable else {
            throw SolidityBridgeError.readOnlyFunction(declaration.signature)
        }
        let calldata = try declaration.calldata(arguments: arguments)
        let call = try makeCall(declaration, calldata: calldata, from: from, value: options.value)
        do {
            return try await client.prepare(call: call, calldata: calldata, from: from, options: options)
        } catch let error as RPCError {
            throw decodeRevert(error) ?? error
        }
    }

    /// Prepares, signs and submits an EIP-1559 transaction. Returns its hash before mining.
    public func send(
        _ function: String,
        arguments: [ABIValue] = [],
        signer: any EthereumSigner,
        options: TransactionOptions = .init()
    ) async throws -> TransactionHash {
        try await submit(function, arguments: arguments, from: signer.address, options: options) { transaction in
            let signature = try await signer.sign(transaction: transaction)
            return try await client.broadcast(transaction, signature: signature)
        }
    }

    private func makeCall(
        _ function: ABIFunction,
        calldata: Data,
        from: EthereumAddress?,
        value: UInt256
    ) throws -> RPCCall {
        guard value == UInt256(0) || function.mutability == .payable else {
            throw SolidityBridgeError.nonPayableFunction(function.signature)
        }
        return RPCCall(from: from, to: address, data: calldata.ethereumHex, value: value == UInt256(0) ? nil : value.hex)
    }

    private func decodeRevert(_ error: RPCError) -> ContractRevert? {
        guard let payload = error.revertData, payload.count >= 4 else { return nil }
        let builtIn = [
            ABIErrorDeclaration(name: "Error", inputs: [.string]),
            ABIErrorDeclaration(name: "Panic", inputs: [.uint(256)])
        ]
        var signatures: Set<String> = []
        var matches: [ContractRevert] = []
        for declaration in builtIn + abi.errors where payload.prefix(4) == declaration.selector {
            guard signatures.insert(declaration.signature).inserted,
                  let arguments = try? ABICodec.decode(declaration.inputs, from: Data(payload.dropFirst(4))) else { continue }
            matches.append(ContractRevert(rpcError: error, signature: declaration.signature, arguments: arguments))
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
