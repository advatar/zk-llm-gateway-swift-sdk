import CryptoKit
import Foundation
import XCTest
@testable import ZKLLMGatewaySDK

final class AppGatewayMockURLProtocolStore: @unchecked Sendable {
    static let shared = AppGatewayMockURLProtocolStore()

    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func getHandler() -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

final class AppGatewayMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = AppGatewayMockURLProtocolStore.shared.getHandler() else {
                throw URLError(.badServerResponse)
            }

            let (response, data) = try handler(request)

            guard let client else { return }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AppGatewayTests: XCTestCase {
    func testFromEnvironmentParsesAliasesAndRelay() throws {
        let config = try AppGatewayConfig.fromEnvironment(
            [
                "GATEWAY_URL": "https://proxy.example.com",
                "GATEWAY_PUBLIC_KEY_B64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "GATEWAY_USE_DUMMY_TICKETS": "true",
                "GATEWAY_USE_RELAY": "true",
                "MODEL": "gpt-4o-mini",
                "TOKEN_CLASS": "c1024",
                "GATEWAY_TEMPERATURE": "0.2",
                "GATEWAY_TIMEOUT_SECS": "30",
            ]
        )

        XCTAssertEqual(config.endpoint.absoluteString, "https://proxy.example.com")
        XCTAssertEqual(config.inferPath, GatewayPaths.relay)
        XCTAssertEqual(config.model, "gpt-4o-mini")
        XCTAssertEqual(config.tokenClass, .c1024)
        XCTAssertEqual(config.temperature, 0.2)
        XCTAssertEqual(config.timeout, 30)
        XCTAssertEqual(config.tickets, .dummy)
    }

    func testAppChatRequestBuilder() {
        let request = AppChatRequest
            .fromUserPrompt("hello")
            .withSystemPrompt("system")
            .withModel("gpt-4o-mini")
            .withTokenClass(.c512)
            .withTemperature(0.1)

        XCTAssertEqual(request.messages, [.user("hello")])
        XCTAssertEqual(request.systemPrompt, "system")
        XCTAssertEqual(request.model, "gpt-4o-mini")
        XCTAssertEqual(request.tokenClass, .c512)
        XCTAssertEqual(request.temperature, 0.1)
    }

    func testAppGatewayAskWithSystemRoundTrip() async throws {
        let gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let gatewayPublicKey = try GatewayPublicKey(rawRepresentation: gatewayPrivateKey.publicKey.rawRepresentation)

        AppGatewayMockURLProtocolStore.shared.setHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body = try appGatewayRequestBody(from: request)
            let requestEnvelope = try JSONDecoder().decode(Envelope.self, from: body)
            let ephData = try XCTUnwrap(Data(base64Encoded: requestEnvelope.ephemeralPublicKeyBase64))
            let clientNonce = try XCTUnwrap(Data(base64Encoded: requestEnvelope.clientNonceBase64))
            let ephPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData)
            let sharedSecret = try gatewayPrivateKey.sharedSecretFromKeyAgreement(with: ephPublicKey)
            let responseKey = deriveKey(
                sharedSecret: sharedSecret,
                tokenClass: requestEnvelope.tokenClass,
                direction: .response,
                requestID: requestEnvelope.requestID,
                clientNonce: clientNonce,
                ephemeralPublicKey: ephData,
                gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
            )

            let payload = JSONValue.object(
                [
                    "kind": .string("ok"),
                    "response": .object(
                        [
                            "request_id": .string(requestEnvelope.requestID),
                            "model": .string("gpt-4o-mini"),
                            "output": .string("hello from the gateway"),
                            "billed_token_class": .string(requestEnvelope.tokenClass.rawValue),
                        ]
                    ),
                ]
            )

            let padded = try padPayload(
                payload.toData(),
                targetLength: requestEnvelope.tokenClass.responsePaddedLength
            )

            let nonceData = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
            let sealedResponse = try ChaChaPoly.seal(
                padded,
                using: SymmetricKey(data: responseKey),
                nonce: try ChaChaPoly.Nonce(data: nonceData),
                authenticating: makeAAD(
                    version: requestEnvelope.version,
                    tokenClass: requestEnvelope.tokenClass,
                    direction: .response,
                    requestID: requestEnvelope.requestID,
                    clientNonce: clientNonce,
                    ephemeralPublicKey: ephData,
                    gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
                )
            )

            var ciphertext = Data(sealedResponse.ciphertext)
            ciphertext.append(sealedResponse.tag)

            let envelope = Envelope(
                version: requestEnvelope.version,
                tokenClass: requestEnvelope.tokenClass,
                requestID: requestEnvelope.requestID,
                clientNonceBase64: requestEnvelope.clientNonceBase64,
                ephemeralPublicKeyBase64: requestEnvelope.ephemeralPublicKeyBase64,
                nonceBase64: nonceData.base64EncodedString(),
                ciphertextBase64: ciphertext.base64EncodedString()
            )

            let data = try JSONEncoder().encode(envelope)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppGatewayMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = GatewayClient(
            endpoint: URL(string: "https://gateway.example.com")!,
            gatewayPublicKey: gatewayPublicKey,
            tickets: DummyTicketSource(),
            urlSession: session
        )

        let gateway = AppGateway(
            client: client,
            defaultModel: "gpt-4o-mini",
            defaultTokenClass: .c2048,
            defaultTemperature: 0.2
        )

        let answer = try await gateway.askWithSystem("You are helpful.", userPrompt: "Hello")
        XCTAssertEqual(answer, "hello from the gateway")
    }
}

private func appGatewayRequestBody(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        throw URLError(.badServerResponse)
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: bufferSize)
        if count < 0 {
            throw stream.streamError ?? URLError(.badServerResponse)
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }

    return data
}
