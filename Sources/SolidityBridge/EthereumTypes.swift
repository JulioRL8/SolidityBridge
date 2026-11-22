import Foundation

public enum SolidityBridgeError: Error, Equatable, Sendable {
    case invalidAddress(String)
    case invalidEndpoint
    case invalidHex(String)
    case invalidQuantity(String)
    case invalidABI(String)
    case unsupportedABIType(String)
    case unknownFunction(String)
    case overloadedFunction(String, signatures: [String])
    case unknownEvent(String)
    case overloadedEvent(String, signatures: [String])
    case anonymousEventFilter(String)
    case unrelatedLog
    case invalidArguments(expected: Int, actual: Int)
    case invalidValue(expected: String)
    case malformedABIData
    case invalidRPCResponse
    case httpStatus(Int)
    case wrongChain(expected: UInt64, actual: UInt64)
    case readOnlyFunction(String)
    case nonPayableFunction(String)
    case invalidFees
    case invalidSignature
    case conflictingSubmission(EthereumAddress)
    case unexpectedTransactionHash(expected: TransactionHash)
}

public struct EthereumAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(_ string: String) throws {
        guard let data = try? Data(ethereumHex: string), data.count == 20 else {
            throw SolidityBridgeError.invalidAddress(string)
        }
        self.bytes = data
        let lower = string.lowercased()
        let payload = string.dropFirst(2)
        guard string == lower || payload == payload.uppercased() || string == description else {
            throw SolidityBridgeError.invalidAddress(string)
        }
    }

    init(bytes: Data) {
        self.bytes = bytes
    }

    /// Derives the Ethereum account from a 65-byte SEC1 uncompressed secp256k1 public key.
    public init(uncompressedPublicKey: Data) throws {
        guard uncompressedPublicKey.count == 65, uncompressedPublicKey.first == 4 else {
            throw WalletError.invalidPublicKey
        }
        self.init(bytes: Data(Keccak256.hash(Data(uncompressedPublicKey.dropFirst())).suffix(20)))
    }

    public var description: String {
        let lower = Array(bytes.ethereumHex.dropFirst(2).utf8)
        let checksum = Keccak256.hash(Data(lower))
        let result = lower.enumerated().map { index, byte in
            let nibble = index.isMultiple(of: 2) ? checksum[index / 2] >> 4 : checksum[index / 2] & 0x0f
            return nibble >= 8 && byte >= 97 ? byte - 32 : byte
        }
        return "0x" + String(decoding: result, as: UTF8.self)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes.ethereumHex)
    }
}

public typealias TransactionHash = Hash32

public struct Hash32: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(_ string: String) throws {
        let bytes = try Data(ethereumHex: string)
        guard bytes.count == 32 else { throw SolidityBridgeError.invalidHex(string) }
        self.bytes = bytes
    }

    init(bytes: Data) {
        self.bytes = bytes
    }

    public var description: String { bytes.ethereumHex }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct UInt256: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Exactly 32 bytes in big-endian order.
    public let bytes: Data

    public init(_ value: UInt64) {
        bytes = Data(repeating: 0, count: 24)
            + Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    public init(decimal string: String) throws {
        let digits = string.utf8
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else {
            throw SolidityBridgeError.invalidQuantity(string)
        }
        var word = [UInt8](repeating: 0, count: 32)
        for digit in digits.drop(while: { $0 == 48 }) {
            var carry = Int(digit - 48)
            for index in word.indices.reversed() {
                carry += Int(word[index]) * 10
                word[index] = UInt8(truncatingIfNeeded: carry)
                carry >>= 8
            }
            guard carry == 0 else { throw SolidityBridgeError.invalidQuantity(string) }
        }
        bytes = Data(word)
    }

    /// Parses an unsigned hexadecimal quantity such as `0xff`.
    public init(hex string: String) throws {
        let digits = string.dropFirst(2)
        guard string.hasPrefix("0x"), (1...64).contains(digits.utf8.count) else {
            throw SolidityBridgeError.invalidQuantity(string)
        }
        let padded = String(repeating: "0", count: 64 - digits.utf8.count) + digits
        guard let bytes = try? Data(ethereumHex: "0x" + padded) else {
            throw SolidityBridgeError.invalidQuantity(string)
        }
        self.bytes = bytes
    }

    init(word: Data) {
        bytes = Data(word)
    }

    public var hex: String {
        let digits = bytes.ethereumHex.dropFirst(2).drop(while: { $0 == "0" })
        return digits.isEmpty ? "0x0" : "0x" + digits
    }

    public var uint64: UInt64? {
        guard bytes.prefix(24).allSatisfy({ $0 == 0 }) else { return nil }
        return bytes.suffix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public var description: String {
        if let uint64 { return String(uint64) }
        var remaining = Array(bytes)
        var digits: [UInt8] = []
        while remaining.contains(where: { $0 != 0 }) {
            var carry = 0
            for index in remaining.indices {
                let dividend = (carry << 8) | Int(remaining[index])
                remaining[index] = UInt8(dividend / 10)
                carry = dividend % 10
            }
            digits.append(UInt8(carry) + 48)
        }
        return String(decoding: digits.reversed(), as: UTF8.self)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    func adding(_ other: Self) throws -> Self {
        var word = Data(repeating: 0, count: 32)
        var carry: UInt16 = 0
        for index in (0..<32).reversed() {
            carry += UInt16(bytes[index]) + UInt16(other.bytes[index])
            word[index] = UInt8(truncatingIfNeeded: carry)
            carry >>= 8
        }
        guard carry == 0 else { throw SolidityBridgeError.invalidFees }
        return Self(word: word)
    }
}

public struct Int256: Hashable, Sendable, CustomStringConvertible {
    /// Exactly 32 bytes in big-endian two's complement.
    public let bytes: Data

    public init(_ value: Int64) {
        let padding: UInt8 = value < 0 ? 0xff : 0
        bytes = Data(repeating: padding, count: 24) + UInt256(UInt64(bitPattern: value)).bytes.suffix(8)
    }

    public init(decimal string: String) throws {
        let isNegative = string.hasPrefix("-")
        let magnitude = try UInt256(decimal: isNegative ? String(string.dropFirst()) : string)
        if isNegative {
            let limit = Data([0x80]) + Data(repeating: 0, count: 31)
            guard !limit.lexicographicallyPrecedes(magnitude.bytes) else {
                throw SolidityBridgeError.invalidQuantity(string)
            }
            bytes = Self.twosComplement(magnitude.bytes)
        } else {
            guard magnitude.bytes[0] < 0x80 else { throw SolidityBridgeError.invalidQuantity(string) }
            bytes = magnitude.bytes
        }
    }

    init(word: Data) {
        bytes = Data(word)
    }

    public var description: String {
        if bytes[0] < 0x80 { return UInt256(word: bytes).description }
        return "-" + UInt256(word: Self.twosComplement(bytes)).description
    }

    private static func twosComplement(_ bytes: Data) -> Data {
        var result = Data(repeating: 0, count: 32)
        var carry: UInt16 = 1
        for index in (0..<32).reversed() {
            carry += UInt16(~bytes[index])
            result[index] = UInt8(truncatingIfNeeded: carry)
            carry >>= 8
        }
        return result
    }
}

extension Data {
    init(ethereumHex string: String) throws {
        let digits = Array(string.utf8)
        guard digits.count >= 2, digits[0] == 48, digits[1] == 120, digits.count.isMultiple(of: 2) else {
            throw SolidityBridgeError.invalidHex(string)
        }
        func nibble(_ byte: UInt8) throws -> UInt8 {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: throw SolidityBridgeError.invalidHex(string)
            }
        }
        self.init()
        reserveCapacity((digits.count - 2) / 2)
        for index in stride(from: 2, to: digits.count, by: 2) {
            try append(nibble(digits[index]) << 4 | nibble(digits[index + 1]))
        }
    }

    var ethereumHex: String {
        let table = Array("0123456789abcdef".utf8)
        var output: [UInt8] = [48, 120]
        output.reserveCapacity(count * 2 + 2)
        for byte in self {
            output.append(table[Int(byte >> 4)])
            output.append(table[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
