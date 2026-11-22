import Foundation

enum ABICodec {
    static func encode(_ types: [ABIType], values: [ABIValue]) throws -> Data {
        guard types.count == values.count else {
            throw SolidityBridgeError.invalidArguments(expected: types.count, actual: values.count)
        }
        let slots = try types.map { try $0.staticSize() }
        let headSize = try slots.reduce(0) { try add($0, $1 ?? 32) }
        var head = Data()
        var tail = Data()
        for (index, type) in types.enumerated() {
            let encoded = try encodeValue(values[index], as: type)
            if slots[index] != nil {
                head.append(encoded)
            } else {
                head.append(word(try add(headSize, tail.count)))
                tail.append(encoded)
            }
        }
        return head + tail
    }

    private static func encodeValue(_ value: ABIValue, as type: ABIType) throws -> Data {
        switch (type, value) {
        case (.address, .address(let address)):
            return Data(repeating: 0, count: 12) + address.bytes
        case (.bool, .bool(let isTrue)):
            return word(isTrue ? 1 : 0)
        case (.uint(let bits), .uint(let integer)) where fitsUnsigned(integer.bytes, bits: bits):
            return integer.bytes
        case (.int(let bits), .int(let integer)) where fitsSigned(integer.bytes, bits: bits):
            return integer.bytes
        case (.fixedBytes(let count), .fixedBytes(let bytes)) where count == bytes.count:
            return bytes + Data(repeating: 0, count: 32 - count)
        case (.bytes, .bytes(let bytes)):
            return encodeLengthPrefixedBytes(bytes)
        case (.string, .string(let string)):
            return encodeLengthPrefixedBytes(Data(string.utf8))
        case (.array(let element, let count), .array(let values)):
            if let count, values.count != count {
                throw SolidityBridgeError.invalidArguments(expected: count, actual: values.count)
            }
            let body = try encode(Array(repeating: element, count: values.count), values: values)
            return count == nil ? word(values.count) + body : body
        case (.tuple(let components), .tuple(let values)):
            return try encode(components, values: values)
        default:
            throw SolidityBridgeError.invalidValue(expected: type.canonicalName)
        }
    }

    static func indexedTopic(_ value: ABIValue, as type: ABIType) throws -> Hash32 {
        let bytes = try encodeIndexed(value, as: type, nested: false)
        switch type {
        case .array, .tuple, .string, .bytes:
            return Hash32(bytes: Keccak256.hash(bytes))
        default:
            return Hash32(bytes: bytes)
        }
    }

    private static func encodeIndexed(_ value: ABIValue, as type: ABIType, nested: Bool) throws -> Data {
        let bytes: Data
        switch (type, value) {
        case (.string, .string(let string)):
            bytes = Data(string.utf8)
        case (.bytes, .bytes(let data)):
            bytes = data
        case (.array(let element, let count), .array(let values)):
            if let count, count != values.count {
                throw SolidityBridgeError.invalidArguments(expected: count, actual: values.count)
            }
            return try values.reduce(into: Data()) { result, item in
                result.append(try encodeIndexed(item, as: element, nested: true))
            }
        case (.tuple(let types), .tuple(let values)):
            guard types.count == values.count else {
                throw SolidityBridgeError.invalidArguments(expected: types.count, actual: values.count)
            }
            return try zip(types, values).reduce(into: Data()) { result, item in
                result.append(try encodeIndexed(item.1, as: item.0, nested: true))
            }
        default:
            return try encodeValue(value, as: type)
        }
        return nested ? bytes + Data(repeating: 0, count: padding(for: bytes.count)) : bytes
    }

    private static func encodeLengthPrefixedBytes(_ bytes: Data) -> Data {
        word(bytes.count) + bytes + Data(repeating: 0, count: padding(for: bytes.count))
    }

    static func decode(_ types: [ABIType], from bytes: Data) throws -> [ABIValue] {
        let bytes = Data(bytes)
        let (values, end) = try decodeSequence(types, from: bytes, start: 0)
        guard end == bytes.count else { throw SolidityBridgeError.malformedABIData }
        return values
    }

    private static func decodeSequence(
        _ types: [ABIType], from bytes: Data, start: Int
    ) throws -> ([ABIValue], Int) {
        let slots = try types.map { try $0.staticSize() }
        let headSize = try slots.reduce(0) { try add($0, $1 ?? 32) }
        var head = start
        var tail = try add(start, headSize)
        guard tail <= bytes.count else { throw SolidityBridgeError.malformedABIData }

        var values: [ABIValue] = []
        values.reserveCapacity(types.count)
        for (index, type) in types.enumerated() {
            if let size = slots[index] {
                let (value, end) = try decodeValue(type, from: bytes, start: head)
                head = try add(head, size)
                guard end == head else { throw SolidityBridgeError.malformedABIData }
                values.append(value)
            } else {
                let offset = try readInteger(from: bytes, start: head)
                guard offset == tail - start else { throw SolidityBridgeError.malformedABIData }
                let (value, end) = try decodeValue(type, from: bytes, start: tail)
                tail = end
                head += 32
                values.append(value)
            }
        }
        return (values, tail)
    }

    private static func decodeValue(
        _ type: ABIType, from bytes: Data, start: Int
    ) throws -> (ABIValue, Int) {
        switch type {
        case .array(let element, let count):
            let elementCount = try count ?? readInteger(from: bytes, start: start)
            let begin = count == nil ? try add(start, 32) : start
            let itemSize = try element.staticSize() ?? 32
            guard begin <= bytes.count, elementCount <= (bytes.count - begin) / itemSize else {
                throw SolidityBridgeError.malformedABIData
            }
            let (values, end) = try decodeSequence(Array(repeating: element, count: elementCount), from: bytes, start: begin)
            return (.array(values), end)
        case .tuple(let types):
            let (values, end) = try decodeSequence(types, from: bytes, start: start)
            return (.tuple(values), end)
        case .bytes, .string:
            let size = try readInteger(from: bytes, start: start)
            let begin = try add(start, 32)
            let contentEnd = try add(begin, size)
            let end = try add(contentEnd, padding(for: size))
            guard end <= bytes.count, bytes[contentEnd..<end].allSatisfy({ $0 == 0 }) else {
                throw SolidityBridgeError.malformedABIData
            }
            let value = bytes[begin..<contentEnd]
            if type == .string {
                guard let string = String(data: value, encoding: .utf8) else {
                    throw SolidityBridgeError.malformedABIData
                }
                return (.string(string), end)
            }
            return (.bytes(Data(value)), end)
        default:
            let end = try add(start, 32)
            guard end <= bytes.count else { throw SolidityBridgeError.malformedABIData }
            let word = Data(bytes[start..<end])
            return (try decodeWord(type, word: word), end)
        }
    }

    private static func decodeWord(_ type: ABIType, word: Data) throws -> ABIValue {
        switch type {
        case .address where word.prefix(12).allSatisfy({ $0 == 0 }):
            return .address(EthereumAddress(bytes: Data(word.suffix(20))))
        case .bool where word.prefix(31).allSatisfy({ $0 == 0 }) && word[31] <= 1:
            return .bool(word[31] == 1)
        case .uint(let bits) where fitsUnsigned(word, bits: bits):
            return .uint(UInt256(word: word))
        case .int(let bits) where fitsSigned(word, bits: bits):
            return .int(Int256(word: word))
        case .fixedBytes(let count) where word.dropFirst(count).allSatisfy({ $0 == 0 }):
            return .fixedBytes(Data(word.prefix(count)))
        default:
            throw SolidityBridgeError.malformedABIData
        }
    }

    private static func fitsUnsigned(_ word: Data, bits: Int) -> Bool {
        word.prefix(32 - bits / 8).allSatisfy { $0 == 0 }
    }

    private static func fitsSigned(_ word: Data, bits: Int) -> Bool {
        let padding = 32 - bits / 8
        let sign: UInt8 = word[padding] >= 0x80 ? 0xff : 0
        return word.prefix(padding).allSatisfy { $0 == sign }
    }

    private static func readInteger(from bytes: Data, start: Int) throws -> Int {
        let end = try add(start, 32)
        guard end <= bytes.count,
              let number = UInt256(word: bytes[start..<end]).uint64,
              let integer = Int(exactly: number) else {
            throw SolidityBridgeError.malformedABIData
        }
        return integer
    }

    private static func word(_ value: Int) -> Data { UInt256(UInt64(value)).bytes }

    private static func padding(for length: Int) -> Int { (32 - length % 32) % 32 }

    static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw SolidityBridgeError.malformedABIData }
        return result
    }
}
