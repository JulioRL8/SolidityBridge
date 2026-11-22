import Foundation
import SolidityBridge
import Testing

private let artifactPath = ProcessInfo.processInfo.environment["SOLIDITYBRIDGE_ANVIL_ARTIFACT"]

@Test(.enabled(if: artifactPath != nil))
func deployAndUseCounterOnAnvil() async throws {
    let path = try #require(artifactPath)
    let endpoint = try #require(URL(string: "http://127.0.0.1:8545"))
    let transport = try HTTPTransport(endpoint: endpoint)
    let client = EthereumClient(chainID: 31337, transport: transport)
    let wallet = ExternalWallet(
        address: try EthereumAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
        session: UnlockedAnvilWallet(transport: transport)
    )
    let artifact = try ContractArtifact(json: Data(contentsOf: URL(fileURLWithPath: path)))
    let deployed = try await client.deploy(artifact, wallet: wallet)
    let deploymentReceipt = try await client.waitForReceipt(for: deployed, pollInterval: .milliseconds(50))
    let address = try #require(deploymentReceipt.contractAddress)
    let counter = client.contract(at: address, abi: artifact.abi)

    #expect(try await counter.read("value") == [.uint(UInt256(0))])
    let receipt = try await counter.execute("set", arguments: [.uint(UInt256(42))], wallet: wallet) { _ in }
    #expect(try await counter.read("value") == [.uint(UInt256(42))])

    let receiptLog = try #require(receipt.logs.first)
    let event = try counter.decodeLog(receiptLog, as: "Updated")
    #expect(try await counter.logs(
        "Updated", from: .number(receipt.blockNumber), to: .number(receipt.blockNumber),
        indexed: [.one(.value(.address(wallet.address))), .one(.value(.string("checkpoint")))]
    ) == [event])

    do {
        _ = try await counter.simulate("set", arguments: [.uint(UInt256(101))])
        Issue.record("Expected TooHigh(uint256)")
    } catch let error as ContractRevert {
        #expect(error.signature == "TooHigh(uint256)")
        #expect(error.arguments == [.uint(UInt256(101))])
    }
}

/// Writes from Anvil's unlocked development account on the fixed loopback endpoint.
private struct UnlockedAnvilWallet: ExternalWalletSession {
    let transport: HTTPTransport

    func sendTransaction(_ request: WalletTransactionRequest, chainID: UInt64) async throws -> TransactionHash {
        #expect(chainID == 31337)
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(Request(id: id, params: [request]))
        let response = try await transport.send(data)
        let decoded = try JSONDecoder().decode(Response.self, from: response)
        #expect(decoded.id == id)
        if let error = decoded.error { throw error }
        return try #require(decoded.result)
    }

    private struct Request: Encodable {
        let jsonrpc = "2.0"
        let method = "eth_sendTransaction"
        let id: String
        let params: [WalletTransactionRequest]
    }

    private struct Response: Decodable {
        let id: String
        let result: TransactionHash?
        let error: RPCError?
    }
}
