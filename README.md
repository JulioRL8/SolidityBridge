# SolidityBridge

SolidityBridge is a Swift package for working with Ethereum smart contracts from iOS and macOS. Configure a chain, an RPC endpoint, a contract address, and its Solidity ABI. Use Swift to read state, simulate calls, send EIP-1559 transactions, deploy contracts, and consume events.

The core library requires Swift 6, iOS 16 or later, or macOS 13 or later. It uses Foundation and has no third-party package dependencies. The optional local signer requires Swift 6.1.

## Install

In Xcode, choose **File → Add Package Dependencies → Add Local…**, select the directory containing `Package.swift`, and add the `SolidityBridge` product to your app target. Add the contract ABI or a compiled artifact containing `abi` to your app resources.

## Read a contract

```swift
import Foundation
import SolidityBridge

func readCounter(rpcURL: URL, address: String, abiData: Data) async throws -> UInt256 {
    let client = try EthereumClient(chainID: 31_337, rpcURL: rpcURL)
    try await client.verifyChain()

    let contract = try client.contract(
        at: EthereumAddress(address),
        abi: ContractABI(json: abiData)
    )
    let result = try await contract.read("value()")
    guard case .uint(let value)? = result.first else {
        throw SolidityBridgeError.malformedABIData
    }
    return value
}
```

This example targets Anvil's default chain. Use the chain ID, endpoint, address, and ABI from your deployment. For the included `Counter.sol`, see the [local walkthrough](Docs/DEVELOPERS.md#run-the-counter-example).

## Choose an API

| I want to… | Start with |
| --- | --- |
| Read state or preview a write | `contract.read` or `contract.simulate` |
| Estimate gas or inspect a prepared transaction | `contract.estimateGas` or `contract.prepareTransaction` |
| Send with a signer or an external wallet | `contract.send` for a hash, or `contract.execute` for progress and a successful receipt |
| Query or watch contract events | `contract.logs`, `contract.logPages`, or `contract.watchLogs` |
| Deploy a compiled contract | `ContractArtifact` and `client.deploy` |
| Generate typed Swift bindings | `swift run soliditybridge-bindings <abi-json> <SwiftType> <output.swift>` |

The ABI codec supports addresses, booleans, signed and unsigned integers from 8 to 256 bits, fixed and dynamic bytes, strings, arrays, and tuples. Fixed-point types and ABI function pointers are outside the current codec. See the [developer guide](Docs/DEVELOPERS.md) for signing, error handling, supported formats, and provider requirements.

## Build and test

```bash
swift test
swift test --package-path LocalWallet
```

Open [SolidityBridgeDemo.xcodeproj](Examples/Demo/SolidityBridgeDemo.xcodeproj) to try the SwiftUI demo. It reads and simulates calls against a deployed `Counter` using generated bindings.

The [developer guide](Docs/DEVELOPERS.md) covers the opt-in Anvil integration test, the demo setup, and the API reference. The [development plan](PLAN.md) records implementation and validation status.
