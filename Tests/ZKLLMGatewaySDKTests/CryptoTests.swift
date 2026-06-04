import CryptoKit
import XCTest
@testable import ZKLLMGatewaySDK

final class CryptoTests: XCTestCase {
    func testSealAndOpenRoundTrip() throws {
        let gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let gatewayPublicKey = try GatewayPublicKey(rawRepresentation: gatewayPrivateKey.publicKey.rawRepresentation)

        let payload: JSONValue = [
            "request_id": .string(UUID().uuidString.lowercased()),
            "hello": "world",
            "n": 123,
        ]

        let sealed = try sealJSON(
            gatewayPublicKey: gatewayPublicKey,
            tokenClass: .c1024,
            payload: payload
        )

        let responsePayload: JSONValue = [
            "upstream": [
                "ok": true,
            ],
        ]

        let ephemeralPublicKeyData = try XCTUnwrap(Data(base64Encoded: sealed.envelope.ephemeralPublicKeyBase64))
        let clientNonce = try XCTUnwrap(Data(base64Encoded: sealed.envelope.clientNonceBase64))
        let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKeyData)
        let sharedSecret = try gatewayPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        let responseKey = deriveKey(
            sharedSecret: sharedSecret,
            tokenClass: .c1024,
            direction: .response,
            requestID: sealed.envelope.requestID,
            clientNonce: clientNonce,
            ephemeralPublicKey: ephemeralPublicKeyData,
            gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
        )

        let paddedResponse = try padPayload(
            responsePayload.toData(),
            targetLength: TokenClass.c1024.responsePaddedLength
        )

        let nonceData = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
        let sealedResponse = try ChaChaPoly.seal(
            paddedResponse,
            using: SymmetricKey(data: responseKey),
            nonce: try ChaChaPoly.Nonce(data: nonceData),
            authenticating: makeAAD(
                version: sealed.envelope.version,
                tokenClass: .c1024,
                direction: .response,
                requestID: sealed.envelope.requestID,
                clientNonce: clientNonce,
                ephemeralPublicKey: ephemeralPublicKeyData,
                gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
            )
        )

        var ciphertext = Data(sealedResponse.ciphertext)
        ciphertext.append(sealedResponse.tag)

        let responseEnvelope = Envelope(
            version: sealed.envelope.version,
            tokenClass: sealed.envelope.tokenClass,
            requestID: sealed.envelope.requestID,
            clientNonceBase64: sealed.envelope.clientNonceBase64,
            ephemeralPublicKeyBase64: sealed.envelope.ephemeralPublicKeyBase64,
            nonceBase64: nonceData.base64EncodedString(),
            ciphertextBase64: ciphertext.base64EncodedString()
        )

        let opened = try openJSON(responseEnvelope, state: sealed.state)
        XCTAssertEqual(opened, responsePayload)
    }
}
