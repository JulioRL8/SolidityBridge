# SolidityBridge Developer Guide

## Contents

- [Install and configure](#install-and-configure)
- [Run the Counter example](#run-the-counter-example)
- [Use the dynamic ABI API](#use-the-dynamic-abi-api)
- [Generate typed bindings](#generate-typed-bindings)
- [Sign and send transactions](#sign-and-send-transactions)
- [Read and watch events](#read-and-watch-events)
- [Deploy a contract](#deploy-a-contract)
- [Handle errors](#handle-errors)
- [Test and troubleshoot](#test-and-troubleshoot)
- [API reference](#api-reference)

## Install and configure

The core package targets iOS 16 and macOS 13 with Swift 6.

### Add the package in Xcode

- Choose **File → Add Package Dependencies…** and paste `https://github.com/JulioRL8/SolidityBridge.git` into the search field.
- Set **Dependency Rule** to **Branch** and enter `master`. The repository does not yet have a version tag.
- Click **Add Package** and select the `SolidityBridge` product for your app target.

### Add the package in Package.swift

Add this entry to the package-level `dependencies` array:

```swift
.package(url: "https://github.com/JulioRL8/SolidityBridge.git", branch: "master")
```

Add this entry to the target's `dependencies` array:

```swift
.product(name: "SolidityBridge", package: "SolidityBridge")
```

### Configure the Ethereum client

Keep a deployment's RPC endpoint, numeric chain ID, address, and ABI together. `ContractABI(json:)` accepts a bare ABI array and an artifact object with an `abi` property. Add the JSON to the app target's resources or load it from a file in a command-line tool. Load the ABI from the contract version you deployed. `EthereumAddress` checks the length and validates the checksum on mixed-case input.

```swift
import Foundation
import SolidityBridge

func connect(
    rpcURL: URL,
    chainID: UInt64,
    address: String,
    abiURL: URL,
    headers: [String: String] = [:]
) async throws -> (client: EthereumClient, contract: EthereumContract) {
    let client = try EthereumClient(chainID: chainID, rpcURL: rpcURL, headers: headers)
    try await client.verifyChain()
    let abi = try ContractABI(json: Data(contentsOf: abiURL))
    let contract = try client.contract(at: EthereumAddress(address), abi: abi)
    return (client, contract)
}
```

The default transport sends JSON-RPC over HTTP or HTTPS with Foundation. Use HTTPS for remote endpoints. If you need a custom `URLSession`, create `HTTPTransport(endpoint:headers:session:)` yourself and pass it to `EthereumClient(chainID:transport:)`. You can also supply your own `RPCTransport`. Call `verifyChain()` during configuration, especially before your first read or event query. The transaction preparation path verifies the chain itself.

## Run the Counter example

From the repository root, start Foundry's local node in one terminal:

```bash
anvil
```

In another terminal, run:

```bash
forge build --contracts Examples
forge create --broadcast --rpc-url http://127.0.0.1:8545 --unlocked \
  --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 Examples/Counter.sol:Counter
```

Copy the contract address printed by Foundry. In [the SwiftUI demo](../Examples/Demo/SolidityBridgeDemo.xcodeproj), enter that address, chain ID `31337`, and a simulator-reachable endpoint such as `http://localhost:8545`. For a physical device, configure a reachable endpoint and the applicable local-network and transport settings. The demo bundles the ABI and generated binding for [Counter.sol](../Examples/Counter.sol).

On a fresh deployment, **Read value** returns 0. **Simulate write** with 42 succeeds, and the next read still returns 0. Simulating 101 reports `TooHigh(uint256)`. The demo exercises reads and simulation. The opt-in integration test also deploys and sends an actual transaction on Anvil.

For Sepolia, use an HTTPS endpoint, chain ID `11155111`, and the address of a `Counter` deployment on Sepolia.

## Use the dynamic ABI API

With an `EthereumContract` from `connect`:

```swift
let result = try await contract.read("value()", at: .latest)
guard case .uint(let value)? = result.first else {
    throw SolidityBridgeError.malformedABIData
}

let arguments: [ABIValue] = [.uint(UInt256(42))]
_ = try await contract.simulate("set(uint256)", arguments: arguments)
let estimatedGas = try await contract.estimateGas(
    "set(uint256)", arguments: arguments, from: sender
)
```

`read` and `simulate` both use `eth_call`. Call `simulate` when you need an explicit `value`, expressed in wei. Provide `from` when the result depends on `msg.sender`, such as for access control or account-specific balances. Supported block selectors are `.latest`, `.pending`, `.safe`, `.finalized`, `.earliest`, and `.number(UInt64)`. Historical reads and some block tags depend on the provider's state retention and tag support. Simulated success reflects the state used for the call. State can change before a transaction is mined.

Resolve a uniquely named function by name. For an overloaded function, provide the canonical signature, including explicit integer widths and tuple syntax. For example, a tuple-array parameter can give the signature `save((address,uint256)[])`. The ABI exposes `functionSignatures` and `eventSignatures` to help with discovery.

| Solidity ABI type | Pass as an `ABIValue` |
| --- | --- |
| `address` | `.address(EthereumAddress)` |
| `bool` | `.bool(Bool)` |
| `uint8…uint256` | `.uint(UInt256)` |
| `int8…int256` | `.int(Int256)` |
| `bytes1…bytes32` | `.fixedBytes(Data)` |
| `bytes` and `string` | `.bytes(Data)` and `.string(String)` |
| Fixed and dynamic arrays | `.array([ABIValue])` |
| Tuples and structs represented as tuples | `.tuple([ABIValue])` in ABI component order |

`UInt256(decimal:)` and `Int256(decimal:)` preserve full integer precision. For example, `try UInt256(decimal: "1000000000000000000")` represents 1 ETH in wei. `uint64` is optional because a 256-bit value may exceed `UInt64.max`. The codec checks the width of ABI integers and lengths of fixed bytes and arrays. The decoder expects Solidity's canonical encoding, including its padding and offsets. Fixed-point types and function pointers are unsupported. See the [Solidity ABI specification](https://docs.soliditylang.org/en/latest/abi-spec.html).

## Generate typed bindings

Generate source from an ABI JSON file or an artifact from Foundry or Hardhat:

```bash
swift run soliditybridge-bindings out/Counter.sol/Counter.json CounterBinding CounterBinding.swift
```

The type name must start with an uppercase letter and be a valid Swift identifier accepted by the generator. Add the output file to your target. Regenerate it when the ABI changes. The generated code depends on `SolidityBridge` and uses its dynamic contract API underneath. Continue supplying the ABI when you create the underlying contract.

```swift
let counter = CounterBinding(contract: contract)
let current = try await counter.value()
try await counter.simulateSet(next: UInt256(42), from: signer.address)
let hash = try await counter.set(next: UInt256(42), signer: signer)
```

Generated tuples use Swift structs. Functions with several return values can use a generated result struct. Overloads carry a selector suffix to distinguish functions whose Solidity parameter types map to the same Swift type. Swift keywords are adjusted while the original ABI signature remains in the generated call. For `Counter`, `decodeUpdatedEvent` decodes a receipt log, and `CounterBinding.TooHighError.decode` converts a matching `ContractRevert` to a typed error payload. Integer widths and fixed byte or array lengths still use runtime ABI validation.

## Sign and send transactions

### Prepare and inspect

```swift
let arguments: [ABIValue] = [.uint(UInt256(42))]
let prepared = try await contract.prepareTransaction(
    "set(uint256)", arguments: arguments, from: signer.address
)
print(prepared.nonce, prepared.gasLimit, prepared.maxFeePerGas)
```

The package uses the node's pending nonce and estimates gas unless you supply `gasLimit`. By default, the priority fee comes from the node and the max fee is twice the latest base fee plus the chosen priority fee. Set either cap through `TransactionOptions`. The max fee must cover the priority fee. `value` is attached ETH in wei, and a nonpayable function rejects a nonzero value. The transaction path uses type-2 EIP-1559 envelopes with an empty access list. Preparing a transaction does not reserve its nonce. `send` and `execute` prepare their own transaction. Review the transaction supplied to your signing or wallet adapter if approval must refer to the exact payload. See [EIP-1559](https://eips.ethereum.org/EIPS/eip-1559).

### Choose a signing path

| Path | App integration | Broadcast |
| --- | --- | --- |
| Custom or hardware signer | Implement `EthereumSigner`, exposing its `address` and returning `EthereumSignature` for the supplied transaction | SolidityBridge calls `eth_sendRawTransaction` |
| Optional local signer | Add `LocalWallet` as a local package in Xcode, link `SolidityBridgeLocalWallet`, and initialize `LocalEthereumSigner(privateKey:)` with 32 key bytes | SolidityBridge calls `eth_sendRawTransaction` |
| Connected external wallet | Implement `ExternalWalletSession` and construct `ExternalWallet(address:session:)` | The wallet session requests `eth_sendTransaction` and returns its hash |

A custom signer signs `transaction.signingDigest` directly with secp256k1. An Ethereum signed-message prefix or a second hash changes the payload. `EthereumSignature(compact:)` accepts `r || s || v` with parity 0/1 or recovery byte 27/28. The signer protocol's address must match the signing account. External wallets should validate the approved account and selected chain in their session. The package supplies the chain ID to the session. The app owns the provider SDK integration, connection, network routing, approvals, and user-facing messages. The optional local signer keeps key material in process memory during its lifetime. The app owns provisioning, persistence, and authorization.

This adapter lets you plug in the request method from your own external wallet SDK. The closure takes the target chain ID and JSON-encoded parameters array, sends the wallet request with method `eth_sendTransaction`, and returns the hash string.

```swift
import Foundation
import SolidityBridge

struct SDKWalletSession: ExternalWalletSession {
    let sendRPC: @Sendable (_ chainID: UInt64, _ params: Data) async throws -> String

    func sendTransaction(
        _ request: WalletTransactionRequest,
        chainID: UInt64
    ) async throws -> TransactionHash {
        let params = try JSONEncoder().encode([request])
        let hash = try await sendRPC(chainID, params)
        return try TransactionHash(hash)
    }
}
```

### Submit and observe

```swift
let hash = try await contract.send(
    "set(uint256)", arguments: [.uint(UInt256(42))], signer: signer
)
let receipt = try await client.waitForReceipt(
    for: hash, timeout: .seconds(120), confirmations: 3
)
guard receipt.succeeded else { throw WalletError.transactionReverted(hash) }
```

Swap `signer:` for `wallet:` to use an external wallet. `receipt(for:)` returns `nil` when the node has no mined receipt. A receipt can represent a reverted transaction, so inspect `succeeded`. `waitForReceipt` defaults to a 60-second polling window, a two-second poll interval, and one confirmation. One confirmation returns on inclusion. With a higher count, the inclusion block counts toward the total and its hash must still match the canonical block at that height. An in-flight RPC call can extend elapsed time past the polling deadline.

Use `execute` to receive progress and get a receipt only when execution succeeded:

```swift
let receipt = try await contract.execute(
    "set(uint256)", arguments: [.uint(UInt256(42))], wallet: wallet
) { state in
    switch state {
    case .awaitingApproval: print("Awaiting signature")
    case .pending(let hash): print("Submitted", hash)
    case .confirmed(let receipt): print("Confirmed", receipt.blockNumber)
    case .failed(let hash, let error): print("Failed", hash as Any, error)
    }
}
```

The callback is asynchronous and `@Sendable`. Update SwiftUI state on the main actor. Errors can occur during preparation before an approval state appears. A timeout or cancellation after submission does not cancel the on-chain transaction. Retain any known hash and check its status separately.

Reuse the client across operations for one chain. The client rejects concurrent submissions from the same address while an approval or broadcast is active. This guard applies within the client instance. The node remains the source for pending nonces, and other apps can use the same account independently.

## Read and watch events

A `ContractEvent` exposes its signature, ordered arguments, and original `EthereumLog`. Use `decodeLog(_:as:)` on a receipt log from the relevant contract and event. A receipt can contain several unrelated logs. For non-anonymous events the first topic is the Keccak-256 hash of the event signature. Indexed scalar values can be decoded from their topics. An indexed string, dynamic bytes value, array, or tuple is available as `.indexedHash`, since the log contains only its hash. Anonymous events can be decoded from known logs by name or signature. Contract event queries require a non-anonymous event. See the [Solidity event ABI](https://docs.soliditylang.org/en/latest/abi-spec.html#events).

```swift
let filter: [EventTopicFilter] = [.any, .one(.value(.string("checkpoint")))]
let events = try await contract.logs(
    "Updated(address,string,uint256)",
    from: .number(1), to: .number(100), indexed: filter
)
```

Filter positions follow the order of indexed arguments. Use `.any` for a wildcard, `.anyOf([...])` for alternatives at one position, and `.hash` for a precomputed topic. A `.value` is encoded using the event field's ABI type, including Solidity's special hashing where applicable.

Use `logPages` for large ranges. Each page represents an inclusive block range, even if it has no events:

```swift
let pages = try contract.logPages(
    "Updated", blocks: 1...10_000, pageSize: 250, indexed: filter
)
for try await page in pages {
    print(page.blocks, page.events.count)
}
```

Use `watchLogs` to continue from a starting block, catch up, and poll for new blocks:

```swift
let watch = try contract.watchLogs(
    "Updated", from: nextBlock, indexed: filter,
    options: .init(
        pageSize: 250, confirmations: 3,
        pollInterval: .seconds(3), reconnectAttempts: 5
    )
)
for try await page in watch {
    print(page.blocks, page.events.count)
}
```

The watch uses HTTP polling and retries the same unprocessed range after a recognized transient error. A new iterator starts from the supplied block. Persist the next block only after you apply a page, and make replay idempotent. When available, use chain ID, block hash, transaction hash, and log index to identify events. If the last delivered checkpoint changes, `.reorganizationDetected(lastDeliveredBlock:)` ends the iteration. Reconcile affected application records and create a new watch from a previously verified block. The error gives the last delivered height. You determine how far back the chains diverged. Cancel the consuming task when its owner no longer needs the stream.

## Deploy a contract

`ContractArtifact(json:)` accepts Foundry's `bytecode.object` or Hardhat's `bytecode` string. Supply the creation artifact with linked bytecode and the constructor ABI. Pass constructor arguments in ABI order. A nonpayable or implicit constructor accepts zero attached value.

```swift
let artifact = try ContractArtifact(json: Data(contentsOf: artifactURL))
let hash = try await client.deploy(artifact, signer: signer)
let receipt = try await client.waitForReceipt(for: hash)
guard receipt.succeeded else { throw WalletError.transactionReverted(hash) }
guard let address = receipt.contractAddress else {
    throw SolidityBridgeError.invalidRPCResponse
}
let deployed = client.contract(at: address, abi: artifact.abi)
```

Use `arguments: [.uint(UInt256(42))]` for a constructor that takes one unsigned integer, or use `wallet:` to deploy through an external wallet. `prepareDeployment` gives you an unsigned transaction for inspection. Its destination is `nil`, and its calldata contains creation bytecode followed by ABI-encoded constructor arguments.

## Handle errors

| Error or symptom | What the caller can do |
| --- | --- |
| `SolidityBridgeError.wrongChain` | Verify the configured chain ID and endpoint. |
| Unknown, overloaded, or malformed ABI function | Check the ABI and use one of its canonical `functionSignatures`. |
| `ContractRevert` | Use `signature` and `arguments` for a user-facing error. A generated binding can decode a known custom error. |
| `RPCError` | Inspect `code`, `message`, and optional `revertData`. Providers can return different error shapes. |
| `TransactionBroadcastError` | Preserve `hash` and inspect `underlyingError`. Check the hash before deciding whether to submit again because the node may have accepted the signed transaction. |
| `WalletError.transactionReverted` | Inspect the receipt using its hash. A mined revert from `execute` reports the hash. It does not supply the original Solidity revert arguments. |
| `ReceiptWaitError.timedOut` | Retain the hash and resume checking later. |
| `EventQueryError.reorganizationDetected` | Reconcile state from a known canonical checkpoint and restart the watcher. |

Recognized reverts include `Error(string)`, `Panic(uint256)`, and custom errors declared by the ABI when the RPC response includes a decodable payload. For a view or simulation, catch `ContractRevert` directly:

```swift
do {
    _ = try await contract.simulate("set(uint256)", arguments: [.uint(UInt256(101))])
} catch let revert as ContractRevert {
    if let error = try CounterBinding.TooHighError.decode(revert) {
        print("Rejected value", error.attempted)
    } else {
        throw revert
    }
}
```

## Test and troubleshoot

Run the core suite with `swift test`. For the optional signer, run `swift test --package-path LocalWallet`. Review the [validation status](../PLAN.md#estado-de-implementacion) for the environments already exercised.

For deterministic app tests, inject an `RPCTransport` and return a JSON-RPC response with the request's ID. This small transport handles the chain verification call:

```swift
import Foundation
import SolidityBridge

struct TestChainTransport: RPCTransport {
    private struct Request: Decodable {
        let id: String
        let method: String
    }

    private struct Response: Encodable {
        let jsonrpc = "2.0"
        let id: String
        let result = "0x7a69"
    }

    func send(_ payload: Data) async throws -> Data {
        let request = try JSONDecoder().decode(Request.self, from: payload)
        guard request.method == "eth_chainId" else {
            throw SolidityBridgeError.invalidRPCResponse
        }
        return try JSONEncoder().encode(Response(id: request.id))
    }
}
```

See [ContractTests.swift](../Tests/SolidityBridgeTests/ContractTests.swift) for examples covering simulations, event backfill, and transaction flow. For the opt-in integration test, start Anvil on its default loopback port, then run:

```bash
forge build --contracts Examples
SOLIDITYBRIDGE_ANVIL_ARTIFACT=out/Counter.sol/Counter.json \
  swift test --filter deployAndUseCounterOnAnvil
```

The test deploys Counter, sends `set(42)` using Anvil's unlocked development account, compares its receipt event with filtered history, and verifies that simulating `set(101)` returns `TooHigh(uint256)`.

| Symptom | Check |
| --- | --- |
| The demo cannot reach a local endpoint | Make sure Anvil is reachable from the simulator or device and check App Transport Security and local-network settings. |
| `eth_call` returns empty or malformed data | Check the chain, deployed address, ABI version, and whether the selected block contains the contract. |
| The provider rejects a history range | Reduce `pageSize` and confirm that the provider retains logs at the requested height. |
| The provider rejects fee discovery | Verify support for type-2 transactions and the provider's fee methods. You can supply both fee caps on a compatible chain. |
| A second write is rejected while a wallet prompt is open | Wait for the active submission before starting another from the same account. |
| A generated method name differs from the ABI name | Look for a keyword adjustment or an overload suffix in the generated source. |

## API reference

| Type | Public entry points and purpose |
| --- | --- |
| `EthereumClient` | `init(chainID:rpcURL:headers:)` or `init(chainID:transport:)`, `contract(at:abi:)`, `verifyChain()`, `blockNumber()`, `receipt(for:)`, `waitForReceipt`, `prepareDeployment`, and both `deploy` overloads. |
| `EthereumContract` | `address`, `abi`, `read`, `simulate`, `estimateGas`, `prepareTransaction`, `send`, `execute`, `logs`, `logPages`, `watchLogs`, and `decodeLog(_:as:)`. |
| `ContractABI`, `ContractArtifact` | Decode JSON. The ABI exposes signature lists. The artifact also exposes creation bytecode. |
| `ABIValue`, `BlockTag` | Supply typed ABI values and select a block context. |
| `EthereumAddress`, `Hash32`, `TransactionHash`, `UInt256`, `Int256` | Represent Ethereum primitives. `TransactionHash` is a typealias of `Hash32`. `UInt256.hex` is a compact RPC quantity, while `bytes` is the full-width word. |
| `TransactionOptions`, `EIP1559Transaction`, `EthereumSignature` | Configure value, gas, and fees. Inspect unsigned fields and access the signing payload and digest. Represent recoverable signature components. |
| `TransactionReceipt`, `EthereumLog`, `ContractEvent`, `ContractRevert` | Inspect mined status, raw events, decoded events, and decoded revert payloads. |
| `EventTopic`, `EventTopicFilter`, `EventWatchOptions` | Configure indexed event filters, page size, confirmation depth, poll interval, and retry limit. |
| `EventPages`, `EventWatch`, `ContractEventPage` | Consume history or ongoing updates as async sequences of inclusive block ranges and decoded events. |
| `EthereumSigner`, `ExternalWalletSession`, `ExternalWallet`, `WalletTransactionRequest`, `TransactionState` | Connect signing or wallet software and observe transaction progress. |
| `RPCTransport`, `HTTPTransport`, `RPCError` | Inject an RPC transport, configure HTTP behavior, and inspect node errors. |
| `LocalEthereumSigner` | The optional `SolidityBridgeLocalWallet` product provides in-process secp256k1 signing. |
| `soliditybridge-bindings` | The command-line product generates Swift source from a contract ABI or artifact. |
