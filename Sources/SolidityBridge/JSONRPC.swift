import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RPCTransport: Sendable {
    func send(_ payload: Data) async throws -> Data
}

public struct HTTPTransport: RPCTransport {
    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession

    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = endpoint.host, !host.isEmpty else {
            throw SolidityBridgeError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    public func send(_ payload: Data) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SolidityBridgeError.invalidRPCResponse }
        guard (200..<300).contains(http.statusCode) else { throw SolidityBridgeError.httpStatus(http.statusCode) }
        return body
    }
}

public struct RPCError: Error, Equatable, Sendable, Decodable {
    public let code: Int
    public let message: String
    public let revertData: Data?

    private enum CodingKeys: String, CodingKey {
        case code, message, data, result, originalError, `return`
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        revertData = (try? container.superDecoder(forKey: .data)).flatMap { Self.findData(in: $0, depth: 0) }
    }

    private static func findData(in decoder: any Decoder, depth: Int) -> Data? {
        guard depth < 5 else { return nil }
        if let container = try? decoder.singleValueContainer(),
           let hex = try? container.decode(String.self) {
            return try? Data(ethereumHex: hex)
        }
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return nil }
        for key in [CodingKeys.data, .result, .return, .originalError] where container.contains(key) {
            if let value = try? container.superDecoder(forKey: key),
               let bytes = findData(in: value, depth: depth + 1) {
                return bytes
            }
        }
        return nil
    }
}

public enum BlockTag: Sendable {
    case latest
    case pending
    case safe
    case finalized
    case earliest
    case number(UInt64)

    var rpcValue: String {
        switch self {
        case .latest: "latest"
        case .pending: "pending"
        case .safe: "safe"
        case .finalized: "finalized"
        case .earliest: "earliest"
        case .number(let number): UInt256(number).hex
        }
    }
}

struct RPCQuantity: Decodable, Sendable {
    let value: UInt256

    init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard string == "0x0" || string.dropFirst(2).first != "0" else {
            throw SolidityBridgeError.invalidQuantity(string)
        }
        value = try UInt256(hex: string)
    }

    func asUInt64() throws -> UInt64 {
        guard let number = value.uint64 else { throw SolidityBridgeError.invalidQuantity(value.hex) }
        return number
    }
}

struct RPCCall: Encodable, Sendable {
    let from: EthereumAddress?
    let to: EthereumAddress?
    let data: String
    let value: String?
    var maxFeePerGas: String? = nil
    var maxPriorityFeePerGas: String? = nil
}

enum RPCLogTopic: Encodable, Sendable {
    case any
    case one(Hash32)
    case alternatives([Hash32])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .any: try container.encodeNil()
        case .one(let hash): try container.encode(hash)
        case .alternatives(let hashes): try container.encode(hashes)
        }
    }
}

struct RPCLogFilter: Encodable, Sendable {
    let address: EthereumAddress
    let fromBlock: String
    let toBlock: String
    let topics: [RPCLogTopic]
}

enum RPCParameter: Encodable, Sendable {
    case string(String)
    case bool(Bool)
    case call(RPCCall)
    case logFilter(RPCLogFilter)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .call(let value): try container.encode(value)
        case .logFilter(let value): try container.encode(value)
        }
    }
}

struct JSONRPC: Sendable {
    let transport: any RPCTransport

    func request<ResultValue: Decodable>(_ method: String, params: [RPCParameter] = []) async throws -> ResultValue {
        let request = Request(id: UUID().uuidString, method: method, params: params)
        let bytes = try await transport.send(JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(Response<ResultValue>.self, from: bytes)
        guard response.id == request.id, response.version == "2.0" else {
            throw SolidityBridgeError.invalidRPCResponse
        }
        return try response.result.get()
    }

    private struct Request: Encodable {
        let jsonrpc = "2.0"
        let id: String
        let method: String
        let params: [RPCParameter]
    }

    private struct Response<Value: Decodable>: Decodable {
        let id: String
        let version: String
        let result: Result<Value, RPCError>

        private enum CodingKeys: String, CodingKey {
            case id, jsonrpc, result, error
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            version = try container.decode(String.self, forKey: .jsonrpc)
            switch (container.contains(.result), container.contains(.error)) {
            case (true, false): result = .success(try container.decode(Value.self, forKey: .result))
            case (false, true): result = .failure(try container.decode(RPCError.self, forKey: .error))
            default: throw SolidityBridgeError.invalidRPCResponse
            }
        }
    }
}
