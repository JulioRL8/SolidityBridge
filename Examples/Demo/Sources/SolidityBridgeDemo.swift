import Foundation
import SolidityBridge
import SwiftUI

@main
struct SolidityBridgeDemo: App {
    var body: some Scene {
        WindowGroup { CounterView() }
    }
}

private struct CounterView: View {
    @State private var endpoint = "http://localhost:8545"
    @State private var chainID = "31337"
    @State private var address = ""
    @State private var proposedValue = "42"
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Contrato Counter") {
                    TextField("URL RPC", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ID de red", text: $chainID)
                        .keyboardType(.numberPad)
                    TextField("Dirección del contrato", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Operaciones") {
                    Button("Leer valor") { run(simulate: false) }
                    TextField("Nuevo valor", text: $proposedValue)
                        .keyboardType(.numberPad)
                    Button("Simular escritura") { run(simulate: true) }
                }
                .disabled(busy)
                if busy {
                    ProgressView()
                }
                if !status.isEmpty {
                    Text(status)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("SolidityBridge")
        }
    }

    private func run(simulate: Bool) {
        busy = true
        status = ""
        Task {
            defer { busy = false }
            do {
                guard let url = URL(string: endpoint), let chain = UInt64(chainID) else {
                    status = "Introduce una URL RPC y un ID de red válidos."
                    return
                }
                guard let abiURL = Bundle.main.url(forResource: "CounterABI", withExtension: "json") else {
                    status = "Falta el ABI de Counter en la aplicación."
                    return
                }
                let client = try EthereumClient(chainID: chain, rpcURL: url)
                let contract = try client.contract(
                    at: EthereumAddress(address), abi: ContractABI(json: Data(contentsOf: abiURL))
                )
                let counter = CounterBinding(contract: contract)
                try await client.verifyChain()
                if simulate {
                    let next = try UInt256(decimal: proposedValue)
                    try await counter.simulateSet(next: next)
                    status = "La simulación de set(\(next)) ha terminado correctamente."
                } else {
                    status = "Valor actual: \(try await counter.value())"
                }
            } catch let revert as ContractRevert {
                if let tooHigh = try? CounterBinding.TooHighError.decode(revert) {
                    status = "El valor \(tooHigh.attempted) supera el máximo de Counter."
                } else {
                    status = "El contrato ha revertido con \(revert.signature)."
                }
            } catch {
                status = String(describing: error)
            }
        }
    }
}
