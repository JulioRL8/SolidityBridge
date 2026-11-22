import Foundation
@_spi(Tooling) import SolidityBridge

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: soliditybridge-bindings <ABI JSON> <Swift type> <output Swift file>\n".utf8))
    exit(64)
}
let input = URL(fileURLWithPath: arguments[arguments.startIndex])
let name = arguments[arguments.index(after: arguments.startIndex)]
let output = URL(fileURLWithPath: arguments[arguments.index(before: arguments.endIndex)])
do {
    let abi = try ContractABI(json: Data(contentsOf: input))
    let source = try SwiftBindingGenerator.generate(abi: abi, named: name)
    try source.write(to: output, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("Binding generation failed: \(error)\n".utf8))
    exit(1)
}
