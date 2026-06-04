import CryptoKit
import Foundation
import XCTest
@testable import ZKLLMGatewaySDK

final class MockURLProtocolStore: @unchecked Sendable {
    static let shared = MockURLProtocolStore()

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

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = MockURLProtocolStore.shared.getHandler() else {
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

final class GatewayClientTests: XCTestCase {
    func testChatCompletionsRoundTrip() async throws {
        let gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let gatewayPublicKey = try GatewayPublicKey(rawRepresentation: gatewayPrivateKey.publicKey.rawRepresentation)

        MockURLProtocolStore.shared.setHandler { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let body = try requestBody(from: request)

            let requestEnvelope = try JSONDecoder().decode(Envelope.self, from: body)
            let requestPayload = try decryptRequestPayload(
                gatewayPrivateKey: gatewayPrivateKey,
                requestEnvelope: requestEnvelope
            )

            XCTAssertEqual(requestPayload["stream"], .bool(false))
            XCTAssertEqual(requestPayload["top_p"], .number(0.1))
            XCTAssertEqual(requestPayload["response_format"], .object(["type": .string("json_object")]))
            XCTAssertEqual(
                requestPayload["tools"],
                .array([.object(["type": .string("function"), "function": .object(["name": .string("lookup_weather")])])])
            )

            let responsePayload = JSONValue.object([
                "kind": .string("ok"),
                "response": .object([
                    "request_id": requestPayload["request_id"] ?? .string(""),
                    "model": .string("gpt-4o-mini"),
                    "output": .string("hello from the gateway"),
                    "billed_token_class": .string(requestEnvelope.tokenClass.rawValue),
                    "upstream": .object([
                        "id": .string("chatcmpl-123"),
                        "model": .string("gpt-4o-mini"),
                        "choices": .array([
                            .object([
                                "index": .number(0),
                                "message": .object([
                                    "role": .string("assistant"),
                                    "content": .string("hello from the gateway"),
                                    "tool_calls": .array([
                                        .object([
                                            "id": .string("call_1"),
                                            "type": .string("function"),
                                            "function": .object([
                                                "name": .string("lookup_weather"),
                                                "arguments": .string("{\"city\":\"Stockholm\"}"),
                                            ]),
                                        ]),
                                    ]),
                                ]),
                                "finish_reason": .string("tool_calls"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
            let envelope = try encryptResponsePayload(
                gatewayPrivateKey: gatewayPrivateKey,
                requestEnvelope: requestEnvelope,
                responsePayload: responsePayload
            )

            let data = try JSONEncoder().encode(envelope)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = GatewayClient(
            endpoint: URL(string: "https://gateway.example.com")!,
            gatewayPublicKey: gatewayPublicKey,
            tickets: DummyTicketSource(),
            urlSession: session
        )

        let response = try await client.chatCompletions(
            tokenClass: .c2048,
            request: ChatCompletionsRequest(
                model: "gpt-4o-mini",
                messages: [
                    .system("You are helpful."),
                    .user("Hello"),
                ],
                temperature: 0.2,
                stream: false,
                extra: [
                    "top_p": .number(0.1),
                    "response_format": .object(["type": .string("json_object")]),
                    "tools": .array([
                        .object([
                            "type": .string("function"),
                            "function": .object(["name": .string("lookup_weather")]),
                        ]),
                    ]),
                ]
            )
        )

        XCTAssertEqual(response.firstText(), "hello from the gateway")
        XCTAssertEqual(response.id, "chatcmpl-123")
        XCTAssertEqual(response.extra["billed_token_class"], .string("c2048"))
        XCTAssertEqual(
            response.choices.first?.message?.extra["tool_calls"],
            .array([
                .object([
                    "id": .string("call_1"),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string("lookup_weather"),
                        "arguments": .string("{\"city\":\"Stockholm\"}"),
                    ]),
                ]),
            ])
        )
    }

    func testInferJSONRejectsStreamTrueOnCanonicalPath() async throws {
        let gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let gatewayPublicKey = try GatewayPublicKey(rawRepresentation: gatewayPrivateKey.publicKey.rawRepresentation)

        MockURLProtocolStore.shared.setHandler { request in
            XCTFail("network should not be reached: \(request)")
            throw URLError(.cannotConnectToHost)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = GatewayClient(
            endpoint: URL(string: "https://gateway.example.com")!,
            gatewayPublicKey: gatewayPublicKey,
            tickets: DummyTicketSource(),
            urlSession: session
        )

        do {
            _ = try await client.inferJSON(
                tokenClass: .c512,
                upstream: ChatCompletionsRequest(
                    model: "gpt-4o-mini",
                    messages: [.user("Hello")],
                    stream: true
                )
            )
            XCTFail("expected stream=true to be rejected")
        } catch let error as ZKLLMGatewayError {
            XCTAssertEqual(error, .protocolViolation("stream=true is not supported on /v1/infer"))
        }
    }
}

private func requestBody(from request: URLRequest) throws -> Data {
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

private func decryptRequestPayload(
    gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    requestEnvelope: Envelope
) throws -> JSONValue {
    guard let ephData = Data(base64Encoded: requestEnvelope.ephemeralPublicKeyBase64) else {
        throw URLError(.cannotDecodeContentData)
    }
    guard let clientNonce = Data(base64Encoded: requestEnvelope.clientNonceBase64) else {
        throw URLError(.cannotDecodeContentData)
    }

    let ephPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData)
    let sharedSecret = try gatewayPrivateKey.sharedSecretFromKeyAgreement(with: ephPublicKey)
    let requestKey = deriveKey(
        sharedSecret: sharedSecret,
        tokenClass: requestEnvelope.tokenClass,
        direction: .request,
        requestID: requestEnvelope.requestID,
        clientNonce: clientNonce,
        ephemeralPublicKey: ephData,
        gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
    )

    guard let nonceData = Data(base64Encoded: requestEnvelope.nonceBase64),
          let ciphertextData = Data(base64Encoded: requestEnvelope.ciphertextBase64)
    else {
        throw URLError(.cannotDecodeContentData)
    }

    let ciphertext = ciphertextData.dropLast(16)
    let tag = ciphertextData.suffix(16)
    let box = try ChaChaPoly.SealedBox(
        nonce: try ChaChaPoly.Nonce(data: nonceData),
        ciphertext: ciphertext,
        tag: tag
    )
    let padded = try ChaChaPoly.open(
        box,
        using: SymmetricKey(data: requestKey),
        authenticating: makeAAD(
            version: requestEnvelope.version,
            tokenClass: requestEnvelope.tokenClass,
            direction: .request,
            requestID: requestEnvelope.requestID,
            clientNonce: clientNonce,
            ephemeralPublicKey: ephData,
            gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation
        )
    )

    let raw = try unpadPayload(padded)
    return try JSONValue.fromData(raw)
}

private func encryptResponsePayload(
    gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    requestEnvelope: Envelope,
    responsePayload: JSONValue
) throws -> Envelope {
    guard let ephData = Data(base64Encoded: requestEnvelope.ephemeralPublicKeyBase64) else {
        throw URLError(.cannotDecodeContentData)
    }
    guard let clientNonce = Data(base64Encoded: requestEnvelope.clientNonceBase64) else {
        throw URLError(.cannotDecodeContentData)
    }

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

    let paddedResponse = try padPayload(
        responsePayload.toData(),
        targetLength: requestEnvelope.tokenClass.responsePaddedLength
    )

    let nonceData = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
    let sealedResponse = try ChaChaPoly.seal(
        paddedResponse,
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

    return Envelope(
        version: requestEnvelope.version,
        tokenClass: requestEnvelope.tokenClass,
        requestID: requestEnvelope.requestID,
        clientNonceBase64: requestEnvelope.clientNonceBase64,
        ephemeralPublicKeyBase64: requestEnvelope.ephemeralPublicKeyBase64,
        nonceBase64: nonceData.base64EncodedString(),
        ciphertextBase64: ciphertext.base64EncodedString()
    )
}
