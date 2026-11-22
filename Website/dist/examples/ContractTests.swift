import Foundation
import SolidityBridge
import Testing

private let contractAddress = "0x00000000000000000000000000000000000000a1"
private let senderAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
private let signedTransaction =
    "0x02f88c827a690307847735940782c3509400000000000000000000000000000000000000a180"
    + "a460fe47b1000000000000000000000000000000000000000000000000000000000000002ac0"
    + "01a0d7fc436c7d02adc3a3f17db1d6c4fb830626240cd80bff1c8f9db86570b68708"
    + "a00755e78f4d475ab33123a5762c986df35a6caa00a90cefbd16ce46a93a28b0ae"
private let txHash = "0x57f561415d16e5da76967b88874995450d533d853381bcecbb76c219f39f855d"
private let eventTopic = "0xd83ab1dd1833cbcb07614fd9a2ce724bbe398d4073d799b8b1b5425298c30408"
private let labelTopic = "0x0f01d8d5f36bc5356cc801e43d2c4e4b360682ecbe538a8c576ec1a7d775975e"
private let value42 = "0x" + String(repeating: "0", count: 62) + "2a"
private let abiJSON = """
[
  {"type":"function","name":"value","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"set","stateMutability":"nonpayable","inputs":[{"type":"uint256"}],"outputs":[]},
  {"type":"error","name":"TooHigh","inputs":[{"type":"uint256"}]},
  {"type":"event","name":"Updated","anonymous":false,"inputs":[
    {"name":"sender","type":"address","indexed":true},
    {"name":"label","type":"string","indexed":true},
    {"name":"value","type":"uint256","indexed":false}
  ]}
]
"""

@Test func contractReadsAndDecodesReverts() async throws {
    let transport = FixtureTransport()
    let client = EthereumClient(chainID: 31337, transport: transport)
    let contract = try makeContract(client)
    #expect(try await contract.read("value", at: .number(3)) == [.uint(UInt256(42))])
    do {
        _ = try await contract.simulate("set", arguments: [.uint(UInt256(42))])
        Issue.record("Expected a Solidity revert")
    } catch let revert as ContractRevert {
        #expect(revert.signature == "TooHigh(uint256)")
        #expect(revert.arguments == [.uint(UInt256(42))])
        #expect(revert.rpcError.code == 3)
    }
}

@Test func contractSignsSendsAndDecodesReceiptAndHistoricalEvents() async throws {
    let transport = FixtureTransport()
    let client = EthereumClient(chainID: 31337, transport: transport)
    let contract = try makeContract(client)
    let signer = FixtureSigner(address: try EthereumAddress(senderAddress))
    let hash = try await contract.send("set", arguments: [.uint(UInt256(42))], signer: signer)
    #expect(hash.description == txHash)
    let receipt = try await client.waitForReceipt(for: hash, pollInterval: .milliseconds(1))
    #expect(receipt.succeeded)
    #expect(receipt.blockNumber == 4)
    let log = try #require(receipt.logs.first)
    let decoded = try contract.decodeLog(log, as: "Updated")
    #expect(decoded.signature == "Updated(address,string,uint256)")
    #expect(decoded.arguments.map(\.name) == ["sender", "label", "value"])
    #expect(decoded.arguments.map(\.value) == [
        .decoded(.address(signer.address)),
        .indexedHash(try Hash32(labelTopic)),
        .decoded(.uint(UInt256(42)))
    ])
    #expect(try await contract.logs("Updated", from: .number(4), to: .number(4)) == [decoded])
    #expect(await transport.methods == [
        "eth_chainId", "eth_getTransactionCount", "eth_maxPriorityFeePerGas", "eth_getBlockByNumber",
        "eth_estimateGas", "eth_sendRawTransaction", "eth_getTransactionReceipt", "eth_getTransactionReceipt", "eth_getLogs"
    ])
}

@Test func wrongChainStopsBeforeSigningOrSending() async throws {
    let transport = FixtureTransport()
    let client = EthereumClient(chainID: 1, transport: transport)
    let contract = try makeContract(client)
    let signer = FixtureSigner(address: try EthereumAddress(senderAddress))
    await #expect(throws: SolidityBridgeError.wrongChain(expected: 1, actual: 31337)) {
        try await contract.send("set", arguments: [.uint(UInt256(42))], signer: signer)
    }
    #expect(await transport.methods == ["eth_chainId"])
}

private func makeContract(_ client: EthereumClient) throws -> EthereumContract {
    try client.contract(at: EthereumAddress(contractAddress), abi: ContractABI(json: Data(abiJSON.utf8)))
}

private struct FixtureSigner: EthereumSigner {
    let address: EthereumAddress

    func sign(transaction: EIP1559Transaction) async throws -> EthereumSignature {
        #expect(transaction.chainID == 31337)
        #expect(transaction.nonce == 3)
        #expect(transaction.gasLimit == 50_000)
        #expect(transaction.maxFeePerGas == UInt256(2_000_000_007))
        #expect(transaction.maxPriorityFeePerGas == UInt256(7))
        #expect(transaction.to == (try EthereumAddress(contractAddress)))
        let digest = try Hash32("0x9b73de0406757900284f7a46f4a5586c740cff7784de7d0e2cb20bc5bfcf1bac")
        #expect(transaction.signingDigest == digest.bytes)
        // Signature created independently with cast mktx for this exact transaction.
        return try EthereumSignature(
            yParity: 1,
            r: UInt256(hex: "0xd7fc436c7d02adc3a3f17db1d6c4fb830626240cd80bff1c8f9db86570b68708"),
            s: UInt256(hex: "0x0755e78f4d475ab33123a5762c986df35a6caa00a90cefbd16ce46a93a28b0ae")
        )
    }
}

private actor FixtureTransport: RPCTransport {
    private(set) var methods: [String] = []
    private var receiptRequests = 0

    func send(_ payload: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let method = try #require(request["method"] as? String)
        let params = try #require(request["params"] as? [Any])
        #expect(request["jsonrpc"] as? String == "2.0")
        methods.append(method)

        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "eth_chainId":
            response["result"] = "0x7a69"
        case "eth_call":
            let call = try #require(params.first as? [String: String])
            #expect(call["to"] == contractAddress)
            if params.last as? String == "0x3" {
                #expect(call["data"] == "0x3fa4f245")
                response["result"] = value42
            } else {
                #expect(call["data"] == "0x60fe47b1" + value42.dropFirst(2))
                response["error"] = ["code": 3, "message": "execution reverted", "data": [
                    "originalError": ["data": "0x279b754f" + value42.dropFirst(2)]
                ]]
            }
        case "eth_getTransactionCount":
            #expect(params as? [String] == [senderAddress, "pending"])
            response["result"] = "0x3"
        case "eth_maxPriorityFeePerGas":
            response["result"] = "0x7"
        case "eth_getBlockByNumber":
            #expect(params.first as? String == "latest")
            #expect(params.last as? Bool == false)
            response["result"] = ["baseFeePerGas": "0x3b9aca00"]
        case "eth_estimateGas":
            let call = try #require(params.first as? [String: String])
            #expect(call["from"] == senderAddress)
            #expect(call["maxFeePerGas"] == "0x77359407")
            #expect(call["maxPriorityFeePerGas"] == "0x7")
            response["result"] = "0xc350"
        case "eth_sendRawTransaction":
            #expect(params as? [String] == [signedTransaction])
            response["result"] = txHash
        case "eth_getTransactionReceipt":
            #expect(params as? [String] == [txHash])
            receiptRequests += 1
            if receiptRequests == 1 {
                response["result"] = NSNull()
            } else {
                response["result"] = [
                    "transactionHash": txHash, "blockNumber": "0x4",
                    "blockHash": "0x" + String(repeating: "7", count: 64),
                    "gasUsed": "0x100", "status": "0x1", "logs": [log]
                ]
            }
        case "eth_getLogs":
            let filter = try #require(params.first as? [String: Any])
            #expect(filter["address"] as? String == contractAddress)
            #expect(filter["fromBlock"] as? String == "0x4")
            #expect(filter["toBlock"] as? String == "0x4")
            #expect(filter["topics"] as? [String] == [eventTopic])
            response["result"] = [log]
        default:
            throw SolidityBridgeError.invalidRPCResponse
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private var log: [String: Any] {
        [
            "address": contractAddress,
            "topics": [eventTopic, "0x" + String(repeating: "0", count: 24) + senderAddress.dropFirst(2), labelTopic],
            "data": value42,
            "transactionHash": txHash,
            "blockNumber": "0x4",
            "logIndex": "0x0"
        ]
    }
}

@Test func watchBackfillsFailedPageAndDetectsReorganization() async throws {
    let transport = EventHistoryTransport()
    let client = EthereumClient(chainID: 31337, transport: transport)
    let contract = try makeContract(client)
    let filters: [EventTopicFilter] = [.any, .anyOf([.value(.string("checkpoint")), .hash(try Hash32(labelTopic))])]
    let stream = try contract.watchLogs(
        "Updated", from: 4, indexed: filters,
        options: .init(pageSize: 1, confirmations: 2, pollInterval: .milliseconds(1))
    )
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next()?.blocks == 4...4)
    #expect(try await iterator.next()?.blocks == 5...5)
    #expect(await transport.ranges == [4...4, 4...4, 5...5])
    await transport.replaceBlock()
    await #expect(throws: EventQueryError.reorganizationDetected(lastDeliveredBlock: 5)) {
        try await iterator.next()
    }
}

@Test func historyPagesFinishAtInclusiveUpperBound() async throws {
    let transport = EventHistoryTransport(failFirstPage: false)
    let contract = try makeContract(EthereumClient(chainID: 31337, transport: transport))
    let pages = try contract.logPages("Updated", blocks: 4...6, pageSize: 2, indexed: [
        .any, .anyOf([.value(.string("checkpoint")), .hash(try Hash32(labelTopic))])
    ])
    var ranges: [ClosedRange<UInt64>] = []
    for try await page in pages { ranges.append(page.blocks) }
    #expect(ranges == [4...5, 6...6])
}

private actor EventHistoryTransport: RPCTransport {
    private(set) var ranges: [ClosedRange<UInt64>] = []
    private let failFirstPage: Bool
    private var reorg = false

    init(failFirstPage: Bool = true) { self.failFirstPage = failFirstPage }

    func replaceBlock() { reorg = true }

    func send(_ payload: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let method = try #require(request["method"] as? String)
        let result: Any
        switch method {
        case "eth_blockNumber":
            result = "0x6"
        case "eth_getBlockByNumber":
            result = ["hash": "0x" + String(repeating: reorg ? "2" : "1", count: 64)]
        case "eth_getLogs":
            let params = try #require(request["params"] as? [[String: Any]])
            let filter = try #require(params.first)
            let start = try UInt256(hex: #require(filter["fromBlock"] as? String))
            let end = try UInt256(hex: #require(filter["toBlock"] as? String))
            ranges.append(try #require(start.uint64)...#require(end.uint64))
            let topics = try #require(filter["topics"] as? [Any])
            #expect(topics.count == 3)
            #expect(topics[0] as? String == eventTopic)
            #expect(topics[1] is NSNull)
            #expect(topics[2] as? [String] == [labelTopic, labelTopic])
            if failFirstPage, ranges.count == 1 { throw URLError(.networkConnectionLost) }
            result = [String]()
        default:
            throw SolidityBridgeError.invalidRPCResponse
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}

@Test func externalWalletDeploysAndWaitsForCanonicalReceipt() async throws {
    let transport = DeploymentTransport()
    let client = EthereumClient(chainID: 31337, transport: transport)
    let wallet = ExternalWallet(address: try EthereumAddress(senderAddress), session: DeploymentWallet())
    let artifact = try ContractArtifact(json: Data("""
    {"abi":[{"type":"constructor","stateMutability":"nonpayable","inputs":[{"name":"next","type":"uint256"}]}],
     "bytecode":{"object":"0x6000"}}
    """.utf8))
    await #expect(throws: ContractDeploymentError.nonPayableConstructor) {
        try await client.prepareDeployment(artifact, from: wallet.address, options: .init(value: UInt256(1)))
    }
    let hash = try await client.deploy(
        artifact, arguments: [.uint(UInt256(42))], wallet: wallet,
        options: .init(gasLimit: 50_000, maxFeePerGas: UInt256(7), maxPriorityFeePerGas: UInt256(7))
    )
    let receipt = try await client.waitForReceipt(for: hash, pollInterval: .milliseconds(1), confirmations: 2)
    #expect(receipt.contractAddress == (try EthereumAddress(contractAddress)))
    #expect(receipt.blockNumber == 5)
}

private struct DeploymentWallet: ExternalWalletSession {
    var contractCreation = true

    func sendTransaction(_ request: WalletTransactionRequest, chainID: UInt64) async throws -> TransactionHash {
        #expect(chainID == 31337)
        let encoded = try JSONEncoder().encode(request)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(fields["from"]?.lowercased() == senderAddress)
        if contractCreation {
            #expect(fields["to"] == nil)
            #expect(fields["data"] == "0x6000" + value42.dropFirst(2))
        } else {
            #expect(fields["to"] == contractAddress)
            #expect(fields["data"] == "0x60fe47b1" + value42.dropFirst(2))
        }
        #expect(fields["nonce"] == "0x3")
        #expect(fields["type"] == "0x2")
        return try TransactionHash(txHash)
    }
}

private actor DeploymentTransport: RPCTransport {
    private var receiptRequests = 0

    func send(_ payload: Data) async throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let method = try #require(request["method"] as? String)
        let canonicalHash = "0x" + String(repeating: "7", count: 64)
        let result: Any
        switch method {
        case "eth_chainId": result = "0x7a69"
        case "eth_getTransactionCount": result = "0x3"
        case "eth_blockNumber": result = "0x6"
        case "eth_getBlockByNumber": result = ["hash": canonicalHash]
        case "eth_getTransactionReceipt":
            receiptRequests += 1
            result = [
                "transactionHash": txHash, "blockNumber": receiptRequests == 1 ? "0x4" : "0x5",
                "blockHash": receiptRequests == 1 ? "0x" + String(repeating: "8", count: 64) : canonicalHash,
                "contractAddress": contractAddress, "gasUsed": "0x100", "status": "0x1", "logs": []
            ]
        default: throw SolidityBridgeError.invalidRPCResponse
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}

@Test func executionReportsApprovalPendingAndConfirmationInOrder() async throws {
    let client = EthereumClient(chainID: 31337, transport: DeploymentTransport())
    let contract = try makeContract(client)
    let wallet = ExternalWallet(
        address: try EthereumAddress(senderAddress),
        session: DeploymentWallet(contractCreation: false)
    )
    let states = StateRecorder()
    let receipt = try await contract.execute(
        "set", arguments: [.uint(UInt256(42))], wallet: wallet,
        options: .init(gasLimit: 50_000, maxFeePerGas: UInt256(7), maxPriorityFeePerGas: UInt256(7))
    ) { await states.record($0) }
    #expect(receipt.succeeded)
    #expect(await states.values == ["approval", "pending", "confirmed"])
}

private actor StateRecorder {
    private(set) var values: [String] = []

    func record(_ state: TransactionState) {
        switch state {
        case .awaitingApproval: values.append("approval")
        case .pending: values.append("pending")
        case .confirmed: values.append("confirmed")
        case .failed: values.append("failed")
        }
    }
}
