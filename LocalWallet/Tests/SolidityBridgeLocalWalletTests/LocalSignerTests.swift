import Foundation
import SolidityBridge
import SolidityBridgeLocalWallet
import Testing

@Test func derivesAddressFromFoundryTestKey() throws {
    var key = Data(repeating: 0, count: 32)
    key[31] = 1
    let signer = try LocalEthereumSigner(privateKey: key)
    #expect(signer.address == (try EthereumAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")))
    #expect(throws: LocalSignerError.invalidPrivateKey) {
        try LocalEthereumSigner(privateKey: Data(repeating: 0, count: 32))
    }
}

@Test func transactionSignatureMatchesFoundry() async throws {
    var key = Data(repeating: 0, count: 32)
    key[31] = 1
    let signer = try LocalEthereumSigner(privateKey: key)
    let address = try EthereumAddress("0x00000000000000000000000000000000000000a1")
    let abi = try ContractABI(json: Data("""
    [{"type":"function","name":"set","stateMutability":"nonpayable",
      "inputs":[{"type":"uint256"}],"outputs":[]}]
    """.utf8))
    let client = EthereumClient(chainID: 31337, transport: SigningTransport())
    let transaction = try await client.contract(at: address, abi: abi).prepareTransaction(
        "set", arguments: [.uint(SolidityBridge.UInt256(42))], from: signer.address,
        options: .init(
            gasLimit: 50_000,
            maxFeePerGas: SolidityBridge.UInt256(2_000_000_007),
            maxPriorityFeePerGas: SolidityBridge.UInt256(7)
        )
    )
    let signature = try await signer.sign(transaction: transaction)
    #expect(signature.yParity == 0)
    #expect(signature.r.hex == "0x86d32d5489c685afae01b001ce00f80a139dce8431e1f7b2c0a2ae82660e682b")
    #expect(signature.s.hex == "0x6ec7f2f27e122a44914a7fb2d1198c61241788127faf2aabe8fc3d0bf73dd024")
}

private struct SigningTransport: RPCTransport {
    func send(_ payload: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let result: String
        switch request["method"] as? String {
        case "eth_chainId": result = "0x7a69"
        case "eth_getTransactionCount": result = "0x3"
        default: throw SolidityBridgeError.invalidRPCResponse
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}
