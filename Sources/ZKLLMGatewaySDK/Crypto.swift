import CryptoKit
import Foundation

public struct GatewayPublicKey: Equatable, Sendable {
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else {
            throw ZKLLMGatewayError.invalidGatewayPublicKey("gateway public key must be 32 bytes")
        }
        self.rawRepresentation = rawRepresentation
    }

    public init(base64: String) throws {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ZKLLMGatewayError.base64("invalid base64 gateway public key")
        }
        guard raw.count == 32 else {
            throw ZKLLMGatewayError.invalidGatewayPublicKey("gateway public key must decode to 32 bytes")
        }
        self.rawRepresentation = raw
    }

    public func toBase64() -> String {
        rawRepresentation.base64EncodedString()
    }

    var keyAgreementPublicKey: Curve25519.KeyAgreement.PublicKey {
        get throws {
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)
        }
    }
}

public struct Envelope: Codable, Equatable, Sendable {
    public var version: Int
    public var tokenClass: TokenClass
    public var ephemeralPublicKeyBase64: String
    public var nonceBase64: String
    public var ciphertextBase64: String

    public init(
        version: Int,
        tokenClass: TokenClass,
        ephemeralPublicKeyBase64: String,
        nonceBase64: String,
        ciphertextBase64: String
    ) {
        self.version = version
        self.tokenClass = tokenClass
        self.ephemeralPublicKeyBase64 = ephemeralPublicKeyBase64
        self.nonceBase64 = nonceBase64
        self.ciphertextBase64 = ciphertextBase64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        guard let version = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("v"))
            ?? container.decodeIfPresent(Int.self, forKey: AnyCodingKey("version"))
        else {
            throw ZKLLMGatewayError.protocolViolation("missing envelope version")
        }

        guard let eph = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("eph_pubkey_b64"))
            ?? container.decodeIfPresent(String.self, forKey: AnyCodingKey("kem_pub_b64"))
        else {
            throw ZKLLMGatewayError.protocolViolation("missing eph_pubkey_b64")
        }

        self.version = version
        self.tokenClass = try container.decode(TokenClass.self, forKey: AnyCodingKey("token_class"))
        self.ephemeralPublicKeyBase64 = eph
        self.nonceBase64 = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("nonce_b64")) ?? ""
        self.ciphertextBase64 = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("ciphertext_b64")) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(version, forKey: AnyCodingKey("v"))
        try container.encode(tokenClass, forKey: AnyCodingKey("token_class"))
        try container.encode(ephemeralPublicKeyBase64, forKey: AnyCodingKey("eph_pubkey_b64"))
        try container.encode(nonceBase64, forKey: AnyCodingKey("nonce_b64"))
        try container.encode(ciphertextBase64, forKey: AnyCodingKey("ciphertext_b64"))
    }
}

public struct SealState: Sendable {
    public let tokenClass: TokenClass

    let ephemeralPublicKey: Data
    let requestKey: Data
    let responseKey: Data
}

enum KeyDirection: UInt8, Sendable {
    case request = 1
    case response = 2
}

func makeAAD(version: Int, tokenClass: TokenClass, direction: KeyDirection) -> Data {
    Data([UInt8(version & 0xFF), tokenClass.id, direction.rawValue])
}

func hkdfInfo(tokenClass: TokenClass, direction: KeyDirection) -> Data {
    var info = Data("zk-llm-gateway-envelope-v1".utf8)
    info.append(contentsOf: direction == .request ? "/req".utf8 : "/resp".utf8)
    info.append(tokenClass.id)
    return info
}

func deriveKey(
    sharedSecret: SharedSecret,
    tokenClass: TokenClass,
    direction: KeyDirection
) -> Data {
    let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(repeating: 0, count: 32),
        sharedInfo: hkdfInfo(tokenClass: tokenClass, direction: direction),
        outputByteCount: 32
    )
    return symmetricKey.withUnsafeBytes { Data($0) }
}

public func sealJSON<T: Encodable>(
    gatewayPublicKey: GatewayPublicKey,
    tokenClass: TokenClass,
    payload: T
) throws -> (envelope: Envelope, state: SealState) {
    let version = 1

    let rawPayload = try JSONEncoder().encode(payload)
    let paddedPayload = try padPayload(rawPayload, targetLength: tokenClass.requestPaddedLength)

    let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation
    let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: gatewayPublicKey.keyAgreementPublicKey)

    let requestKey = deriveKey(sharedSecret: sharedSecret, tokenClass: tokenClass, direction: .request)
    let responseKey = deriveKey(sharedSecret: sharedSecret, tokenClass: tokenClass, direction: .response)
    let nonceData = randomNonceData()

    let sealedBox = try ChaChaPoly.seal(
        paddedPayload,
        using: SymmetricKey(data: requestKey),
        nonce: try ChaChaPoly.Nonce(data: nonceData),
        authenticating: makeAAD(version: version, tokenClass: tokenClass, direction: .request)
    )

    let ciphertext = sealedBox.ciphertext + sealedBox.tag

    return (
        envelope: Envelope(
            version: version,
            tokenClass: tokenClass,
            ephemeralPublicKeyBase64: ephemeralPublicKey.base64EncodedString(),
            nonceBase64: nonceData.base64EncodedString(),
            ciphertextBase64: ciphertext.base64EncodedString()
        ),
        state: SealState(
            tokenClass: tokenClass,
            ephemeralPublicKey: ephemeralPublicKey,
            requestKey: requestKey,
            responseKey: responseKey
        )
    )
}

public func openJSON(_ envelope: Envelope, state: SealState) throws -> JSONValue {
    guard envelope.version == 1 else {
        throw ZKLLMGatewayError.crypto("unsupported envelope version")
    }

    guard envelope.tokenClass == state.tokenClass else {
        throw ZKLLMGatewayError.crypto("token_class mismatch")
    }

    guard let ephemeralPublicKey = Data(base64Encoded: envelope.ephemeralPublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let nonceData = Data(base64Encoded: envelope.nonceBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let ciphertextAndTag = Data(base64Encoded: envelope.ciphertextBase64.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        throw ZKLLMGatewayError.base64("invalid base64 envelope field")
    }

    guard ephemeralPublicKey.count == 32, nonceData.count == 12, ciphertextAndTag.count >= 16 else {
        throw ZKLLMGatewayError.crypto("invalid envelope fields")
    }

    guard ephemeralPublicKey == state.ephemeralPublicKey else {
        throw ZKLLMGatewayError.crypto("unexpected eph_pubkey in response")
    }

    let ciphertext = ciphertextAndTag.prefix(ciphertextAndTag.count - 16)
    let tag = ciphertextAndTag.suffix(16)
    let sealedBox = try ChaChaPoly.SealedBox(
        nonce: ChaChaPoly.Nonce(data: nonceData),
        ciphertext: ciphertext,
        tag: tag
    )

    let padded = try ChaChaPoly.open(
        sealedBox,
        using: SymmetricKey(data: state.responseKey),
        authenticating: makeAAD(version: envelope.version, tokenClass: envelope.tokenClass, direction: .response)
    )

    let raw = try unpadPayload(padded)

    do {
        return try JSONValue.fromData(raw)
    } catch {
        throw ZKLLMGatewayError.protocolViolation("invalid decrypted JSON: \(error.localizedDescription)")
    }
}

public func openJSON<T: Decodable>(_ envelope: Envelope, state: SealState, as type: T.Type) throws -> T {
    let json = try openJSON(envelope, state: state)
    return try json.decode(type)
}

private func randomNonceData() -> Data {
    Data((0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
}
