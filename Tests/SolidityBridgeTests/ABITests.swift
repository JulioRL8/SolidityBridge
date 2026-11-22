import Foundation
import Testing
@testable import SolidityBridge

@Test func keccakAndAddressMatchEthereumVectors() throws {
    #expect(Keccak256.hash(Data()).ethereumHex == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    #expect(Keccak256.hash(Data("hello".utf8)).ethereumHex == "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    let address = try EthereumAddress("0x5aeda56215b167893e80b4fe645ba6d5bab767de")
    #expect(address.description == "0x5AEDA56215b167893e80B4fE645BA6d5Bab767DE")
    #expect(throws: SolidityBridgeError.invalidAddress("0x5aEDA56215b167893e80B4fE645BA6d5Bab767DE")) {
        try EthereumAddress("0x5aEDA56215b167893e80B4fE645BA6d5Bab767DE")
    }
}

@Test func nestedABIMatchesCastEncoding() throws {
    // cast abi-encode 'f((uint256,string)[],int8,bytes3,string[2])' '[(42,uno),(7,dos)]' -128 0xa1b2c3 '[izquierda,derecha]'
    let words = """
    0000000000000000000000000000000000000000000000000000000000000080
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff80
    a1b2c30000000000000000000000000000000000000000000000000000000000
    00000000000000000000000000000000000000000000000000000000000001e0
    0000000000000000000000000000000000000000000000000000000000000002
    0000000000000000000000000000000000000000000000000000000000000040
    00000000000000000000000000000000000000000000000000000000000000c0
    000000000000000000000000000000000000000000000000000000000000002a
    0000000000000000000000000000000000000000000000000000000000000040
    0000000000000000000000000000000000000000000000000000000000000003
    756e6f0000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000007
    0000000000000000000000000000000000000000000000000000000000000040
    0000000000000000000000000000000000000000000000000000000000000003
    646f730000000000000000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000040
    0000000000000000000000000000000000000000000000000000000000000080
    0000000000000000000000000000000000000000000000000000000000000009
    697a717569657264610000000000000000000000000000000000000000000000
    0000000000000000000000000000000000000000000000000000000000000007
    6465726563686100000000000000000000000000000000000000000000000000
    """
    let expected = try Data(ethereumHex: "0x" + words.split(whereSeparator: \.isWhitespace).joined())
    let abi = try ContractABI(json: Data("""
    {"abi":[{"type":"function","name":"f","stateMutability":"pure","outputs":[],
    "inputs":[{"type":"tuple[]","components":[{"type":"uint256"},{"type":"string"}]},
              {"type":"int8"},{"type":"bytes3"},{"type":"string[2]"}]}]}
    """.utf8))
    let function = try abi.function("f((uint256,string)[],int8,bytes3,string[2])")
    let values: [ABIValue] = [
        .array([.tuple([.uint(UInt256(42)), .string("uno")]), .tuple([.uint(UInt256(7)), .string("dos")])]),
        .int(Int256(-128)), .fixedBytes(Data([0xa1, 0xb2, 0xc3])), .array([.string("izquierda"), .string("derecha")])
    ]
    #expect(try ABICodec.encode(function.inputs, values: values) == expected)
    #expect(try ABICodec.decode(function.inputs, from: expected) == values)
    #expect(throws: SolidityBridgeError.malformedABIData) {
        try ABICodec.decode(function.inputs, from: Data(expected.dropLast()))
    }
    var badOffset = expected
    badOffset[31] = 0
    #expect(throws: SolidityBridgeError.malformedABIData) {
        try ABICodec.decode(function.inputs, from: badOffset)
    }
}

@Test func integersPreserveFullSolidityRange() throws {
    let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    let minimumSigned = "-57896044618658097711785492504343953926634992332820282019728792003956564819968"
    #expect(try UInt256(decimal: maximum).description == maximum)
    #expect(try UInt256(decimal: maximum).hex == "0x" + String(repeating: "f", count: 64))
    #expect(try Int256(decimal: minimumSigned).description == minimumSigned)
    #expect(throws: SolidityBridgeError.invalidQuantity(maximum + "0")) {
        try UInt256(decimal: maximum + "0")
    }
    #expect(throws: SolidityBridgeError.invalidValue(expected: "int8")) {
        try ABICodec.encode([.int(8)], values: [.int(Int256(128))])
    }
    #expect(throws: SolidityBridgeError.invalidValue(expected: "uint8")) {
        try ABICodec.encode([.uint(8)], values: [.uint(UInt256(256))])
    }
}

@Test func functionOverloadsRequireCanonicalSignature() throws {
    let abi = try ContractABI(json: Data("""
    [
      {"type":"function","name":"f","stateMutability":"pure","inputs":[{"type":"uint256"}],"outputs":[]},
      {"type":"function","name":"f","stateMutability":"pure","inputs":[{"type":"address"}],"outputs":[]}
    ]
    """.utf8))
    #expect(throws: SolidityBridgeError.overloadedFunction("f", signatures: ["f(uint256)", "f(address)"])) {
        try abi.function("f")
    }
    #expect(try abi.function("f(address)").signature == "f(address)")
}
