import Foundation

public indirect enum ABIValue: Equatable, Sendable {
    case address(EthereumAddress)
    case bool(Bool)
    case uint(UInt256)
    case int(Int256)
    case fixedBytes(Data)
    case bytes(Data)
    case string(String)
    case array([ABIValue])
    case tuple([ABIValue])
}

enum FunctionMutability: String, Decodable, Sendable {
    case pure
    case view
    case nonpayable
    case payable
}

public struct ContractABI: Sendable {
    let functions: [ABIFunction]
    let errors: [ABIErrorDeclaration]
    let events: [ABIEvent]
    let constructor: ABIConstructor?
    let entries: [ABIEntry]

    /// Accepts an ABI array or a Solidity build artifact containing an `abi` array.
    public init(json: Data) throws {
        let decoder = JSONDecoder()
        let entries: [ABIEntry]
        if json.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            entries = try decoder.decode([ABIEntry].self, from: json)
        } else {
            entries = try decoder.decode(Artifact.self, from: json).abi
        }

        var functions: [ABIFunction] = []
        var errors: [ABIErrorDeclaration] = []
        var events: [ABIEvent] = []
        var constructor: ABIConstructor?
        var signatures: Set<String> = []
        for entry in entries {
            switch entry.type {
            case "constructor":
                guard constructor == nil, let inputs = entry.inputs, let mutability = entry.stateMutability,
                      mutability == .payable || mutability == .nonpayable else {
                    throw SolidityBridgeError.invalidABI("Invalid or duplicate constructor declaration")
                }
                constructor = ABIConstructor(inputs: try inputs.map { try ABIType($0) }, payable: mutability == .payable)
            case "function":
                guard let name = entry.name, !name.isEmpty,
                      let inputs = entry.inputs, let outputs = entry.outputs,
                      let mutability = entry.stateMutability else {
                    throw SolidityBridgeError.invalidABI("Incomplete function declaration")
                }
                let function = ABIFunction(
                    name: name,
                    inputs: try inputs.map { try ABIType($0) },
                    outputs: try outputs.map { try ABIType($0) },
                    mutability: mutability
                )
                guard signatures.insert(function.signature).inserted else {
                    throw SolidityBridgeError.invalidABI("Duplicate function: " + function.signature)
                }
                functions.append(function)
            case "error":
                guard let name = entry.name, !name.isEmpty, let inputs = entry.inputs else {
                    throw SolidityBridgeError.invalidABI("Incomplete error declaration")
                }
                let declaration = ABIErrorDeclaration(name: name, inputs: try inputs.map { try ABIType($0) })
                if !errors.contains(where: { $0.signature == declaration.signature }) {
                    errors.append(declaration)
                }
            case "event":
                guard let name = entry.name, !name.isEmpty,
                      let inputs = entry.inputs, let anonymous = entry.anonymous else {
                    throw SolidityBridgeError.invalidABI("Incomplete event declaration")
                }
                let fields = try inputs.map { parameter in
                    guard let indexed = parameter.indexed else {
                        throw SolidityBridgeError.invalidABI("Missing indexed flag for " + name)
                    }
                    return ABIEvent.Field(name: parameter.name ?? "", type: try ABIType(parameter), indexed: indexed)
                }
                guard fields.filter(\.indexed).count <= (anonymous ? 4 : 3) else {
                    throw SolidityBridgeError.invalidABI("Too many indexed inputs for " + name)
                }
                let event = ABIEvent(name: name, fields: fields, anonymous: anonymous)
                guard !events.contains(where: { $0.signature == event.signature }) else {
                    throw SolidityBridgeError.invalidABI("Duplicate event: " + event.signature)
                }
                events.append(event)
            default:
                continue
            }
        }
        self.functions = functions
        self.errors = errors
        self.events = events
        self.constructor = constructor
        self.entries = entries
    }

    public var functionSignatures: [String] { functions.map(\.signature) }
    public var eventSignatures: [String] { events.map(\.signature) }

    func event(_ nameOrSignature: String) throws -> ABIEvent {
        let matches = events.filter { $0.name == nameOrSignature || $0.signature == nameOrSignature }
        guard let match = matches.first else { throw SolidityBridgeError.unknownEvent(nameOrSignature) }
        guard matches.count == 1 else {
            throw SolidityBridgeError.overloadedEvent(nameOrSignature, signatures: matches.map(\.signature))
        }
        return match
    }

    func function(_ functionOrSignature: String) throws -> ABIFunction {
        if functionOrSignature.contains("(") {
            guard let match = functions.first(where: { $0.signature == functionOrSignature }) else {
                throw SolidityBridgeError.unknownFunction(functionOrSignature)
            }
            return match
        }

        let matches = functions.filter { $0.name == functionOrSignature }
        guard let match = matches.first else { throw SolidityBridgeError.unknownFunction(functionOrSignature) }
        guard matches.count == 1 else {
            throw SolidityBridgeError.overloadedFunction(functionOrSignature, signatures: matches.map(\.signature))
        }
        return match
    }

    private struct Artifact: Decodable {
        let abi: [ABIEntry]
    }
}

struct ABIConstructor: Sendable {
    let inputs: [ABIType]
    let payable: Bool
}

struct ABIFunction: Sendable {
    let name: String
    let inputs: [ABIType]
    let outputs: [ABIType]
    let mutability: FunctionMutability

    var signature: String { abiSignature(name: name, inputs: inputs) }
    var selector: Data { abiSelector(signature) }

    func calldata(arguments: [ABIValue]) throws -> Data {
        try selector + ABICodec.encode(inputs, values: arguments)
    }
}

struct ABIErrorDeclaration: Sendable {
    let name: String
    let inputs: [ABIType]

    var signature: String { abiSignature(name: name, inputs: inputs) }
    var selector: Data { abiSelector(signature) }
}

func abiSignature(name: String, inputs: [ABIType]) -> String {
    name + "(" + inputs.map(\.canonicalName).joined(separator: ",") + ")"
}

private func abiSelector(_ signature: String) -> Data {
    Data(Keccak256.hash(Data(signature.utf8)).prefix(4))
}

struct ABIEntry: Decodable, Sendable {
    let type: String
    let name: String?
    let inputs: [ABIParameter]?
    let outputs: [ABIParameter]?
    let stateMutability: FunctionMutability?
    let anonymous: Bool?
}

struct ABIParameter: Decodable, Sendable {
    let type: String
    let components: [ABIParameter]?
    var name: String? = nil
    var indexed: Bool? = nil
}

indirect enum ABIType: Equatable, Sendable {
    case address
    case bool
    case uint(Int)
    case int(Int)
    case fixedBytes(Int)
    case bytes
    case string
    case array(ABIType, count: Int?)
    case tuple([ABIType])

    init(_ parameter: ABIParameter, depth: Int = 0) throws {
        guard depth < 32 else { throw SolidityBridgeError.invalidABI("ABI type nesting exceeds 32 levels") }
        let name = parameter.type
        if name.last == "]", let opening = name.lastIndex(of: "[") {
            let length = name[name.index(after: opening)..<name.index(before: name.endIndex)]
            let count = length.isEmpty ? nil : Int(length)
            guard length.isEmpty || (length.utf8.allSatisfy({ (48...57).contains($0) }) && (count ?? 0) > 0) else {
                throw SolidityBridgeError.unsupportedABIType(name)
            }
            let element = ABIParameter(type: String(name[..<opening]), components: parameter.components)
            self = .array(try ABIType(element, depth: depth + 1), count: count)
            return
        }

        switch name {
        case "address": self = .address
        case "bool": self = .bool
        case "bytes": self = .bytes
        case "string": self = .string
        case "uint": self = .uint(256)
        case "int": self = .int(256)
        case "tuple":
            guard let components = parameter.components, !components.isEmpty else {
                throw SolidityBridgeError.invalidABI("Missing tuple components")
            }
            self = .tuple(try components.map { try ABIType($0, depth: depth + 1) })
        default:
            if name.hasPrefix("uint"), let bits = Self.readSize(name.dropFirst(4), within: 8...256),
               bits.isMultiple(of: 8) {
                self = .uint(bits)
            } else if name.hasPrefix("int"), let bits = Self.readSize(name.dropFirst(3), within: 8...256),
                      bits.isMultiple(of: 8) {
                self = .int(bits)
            } else if name.hasPrefix("bytes"), let size = Self.readSize(name.dropFirst(5), within: 1...32) {
                self = .fixedBytes(size)
            } else {
                throw SolidityBridgeError.unsupportedABIType(name)
            }
        }
    }

    private static func readSize(_ digits: Substring, within range: ClosedRange<Int>) -> Int? {
        guard digits.first != "0", digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(digits), range.contains(number) else { return nil }
        return number
    }

    var canonicalName: String {
        switch self {
        case .address: "address"
        case .bool: "bool"
        case .uint(let bits): "uint" + String(bits)
        case .int(let bits): "int" + String(bits)
        case .fixedBytes(let size): "bytes" + String(size)
        case .bytes: "bytes"
        case .string: "string"
        case .array(let type, let count): type.canonicalName + "[" + (count.map(String.init) ?? "") + "]"
        case .tuple(let types): "(" + types.map(\.canonicalName).joined(separator: ",") + ")"
        }
    }

    func staticSize() throws -> Int? {
        switch self {
        case .bytes, .string, .array(_, nil):
            return nil
        case .array(let element, let count?):
            guard let elementSize = try element.staticSize() else { return nil }
            let (size, overflow) = elementSize.multipliedReportingOverflow(by: count)
            guard !overflow else { throw SolidityBridgeError.invalidABI("Static array is too large") }
            return size
        case .tuple(let types):
            var size = 0
            for type in types {
                guard let itemSize = try type.staticSize() else { return nil }
                size = try ABICodec.add(size, itemSize)
            }
            return size
        default:
            return 32
        }
    }
}
