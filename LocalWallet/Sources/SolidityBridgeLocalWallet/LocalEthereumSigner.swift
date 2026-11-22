import Foundation
import Security
import SolidityBridge
import libsecp256k1

public enum LocalSignerError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case contextCreationFailed
    case randomnessFailed(OSStatus)
    case signingFailed
}

/// Keeps the supplied key in process memory for the lifetime of the signer.
/// Key import, persistent storage and user authentication are owned by the app.
public struct LocalEthereumSigner: EthereumSigner {
    public let address: EthereumAddress
    private let privateKey: Data

    public init(privateKey: Data) throws {
        guard privateKey.count == 32 else { throw LocalSignerError.invalidPrivateKey }
        address = try Self.withContext { context in
            var publicKey = secp256k1_pubkey()
            guard privateKey.withUnsafeBytes({ buffer in
                secp256k1_ec_pubkey_create(context, &publicKey, buffer.bindMemory(to: UInt8.self).baseAddress!)
            }) == 1 else { throw LocalSignerError.invalidPrivateKey }
            var bytes = [UInt8](repeating: 0, count: 65)
            var size = bytes.count
            guard secp256k1_ec_pubkey_serialize(context, &bytes, &size, &publicKey, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1,
                  size == bytes.count else { throw WalletError.invalidPublicKey }
            return try EthereumAddress(uncompressedPublicKey: Data(bytes))
        }
        self.privateKey = privateKey
    }

    public func sign(transaction: EIP1559Transaction) async throws -> EthereumSignature {
        guard transaction.from == address else { throw WalletError.accountMismatch }
        try Task.checkCancellation()
        return try Self.withContext { context in
            var signature = secp256k1_ecdsa_recoverable_signature()
            let digest = [UInt8](transaction.signingDigest)
            let signed = privateKey.withUnsafeBytes { buffer in
                secp256k1_ecdsa_sign_recoverable(
                    context, &signature, digest, buffer.bindMemory(to: UInt8.self).baseAddress!, nil, nil
                )
            }
            guard signed == 1 else { throw LocalSignerError.signingFailed }
            var compact = [UInt8](repeating: 0, count: 64)
            var recovery: Int32 = 0
            guard secp256k1_ecdsa_recoverable_signature_serialize_compact(context, &compact, &recovery, &signature) == 1,
                  let parity = UInt8(exactly: recovery), parity <= 1 else { throw LocalSignerError.signingFailed }
            compact.append(parity)
            return try EthereumSignature(compact: Data(compact))
        }
    }

    private static func withContext<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else {
            throw LocalSignerError.contextCreationFailed
        }
        defer { secp256k1_context_destroy(context) }
        var seed = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed)
        guard status == errSecSuccess else { throw LocalSignerError.randomnessFailed(status) }
        guard secp256k1_context_randomize(context, &seed) == 1 else { throw LocalSignerError.contextCreationFailed }
        return try body(context)
    }
}
