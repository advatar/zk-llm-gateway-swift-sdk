import Foundation
import XCTest
@testable import ZKLLMGatewaySDK

final class PreparedInferenceTests: XCTestCase {
    private actor Authorizer: PreparedAuthorizationProviding {
        private(set) var calls = 0
        let commitment: Data

        init(commitment: Data = Data(repeating: 7, count: 48)) {
            self.commitment = commitment
        }

        func authorize(_ prepared: PreparedInference) async throws -> PreparedAuthorization {
            calls += 1
            let ticket = ZkTicket(
                commitmentRoot: commitment.base64EncodedString(),
                nullifier: Data("synthetic-nullifier".utf8).base64EncodedString(),
                tokenClass: prepared.tokenClass,
                proof: Data("NOT-REAL-FINALITY".utf8).base64EncodedString()
            )
            return try PreparedAuthorization(commitment: commitment, ticket: ticket)
        }

        func callCount() -> Int { calls }
    }

    private let fixedID = UUID(uuidString: "12345678-1234-4234-9234-123456789abc")!

    func testPreparationFreezesRequestIDAndCanonicalProjection() throws {
        var request = ChatCompletionsRequest(
            model: "synthetic-model",
            messages: [.user("Ålder?")],
            temperature: 0.5,
            maxTokens: 256,
            stream: false,
            extra: ["seed": 7, "response_format": ["type": "json_object"]]
        )
        let prepared = try PreparedInference.prepare(tokenClass: .c512, request: request, requestID: fixedID)
        let original = prepared.canonicalAuthorizationProjection
        request.messages[0].content = "changed"
        request.extra["seed"] = 8
        XCTAssertEqual(prepared.requestID, "12345678-1234-4234-9234-123456789abc")
        XCTAssertEqual(prepared.model, "synthetic-model")
        XCTAssertEqual(prepared.canonicalAuthorizationProjection, original)
        let text = String(decoding: original, as: UTF8.self)
        XCTAssertTrue(text.contains("\"provider_options\""))
        XCTAssertTrue(text.contains("\"request_id\":\"12345678-1234-4234-9234-123456789abc\""))
    }

    func testAuthorizationIsRequestedAfterPreparation() async throws {
        let prepared = try PreparedInference.prepare(
            tokenClass: .c256,
            request: .init(model: "synthetic-model", messages: [.user("synthetic")]),
            requestID: fixedID
        )
        let authorizer = Authorizer()
        let authorized = try await prepared.authorize(using: authorizer)
        let calls = await authorizer.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(authorized.prepared.requestID, prepared.requestID)
        XCTAssertEqual(authorized.authorization.ticket.tokenClass, .c256)
    }

    func testReservedOptionFailsBeforeAuthorization() async throws {
        let authorizer = Authorizer()
        do {
            _ = try PreparedInference.prepare(
                tokenClass: .c256,
                request: .init(
                    model: "synthetic-model",
                    messages: [.user("synthetic")],
                    extra: ["authorization": "secret"]
                ),
                requestID: fixedID
            )
            XCTFail("reserved option must fail")
        } catch {
            let calls = await authorizer.callCount()
            XCTAssertEqual(calls, 0)
        }
    }

    func testUnqualifiedFloatAndStreamingFailClosed() throws {
        XCTAssertThrowsError(try PreparedInference.prepare(
            tokenClass: .c256,
            request: .init(model: "synthetic-model", messages: [.user("x")], temperature: 0.2),
            requestID: fixedID
        ))
        XCTAssertThrowsError(try PreparedInference.prepare(
            tokenClass: .c256,
            request: .init(model: "synthetic-model", messages: [.user("x")], stream: true),
            requestID: fixedID
        ))
        XCTAssertThrowsError(try PreparedInference.prepare(
            tokenClass: .c256,
            request: .init(model: "synthetic-model", messages: [.user("x")], extra: ["top_p": 0.9]),
            requestID: fixedID
        ))
    }

    func testAuthorizationCommitmentMustMatchTicket() throws {
        let commitment = Data(repeating: 1, count: 48)
        let ticket = ZkTicket(
            commitmentRoot: Data(repeating: 2, count: 48).base64EncodedString(),
            nullifier: "bnVsbGlmaWVy",
            tokenClass: .c256,
            proof: "cHJvb2Y="
        )
        XCTAssertThrowsError(try PreparedAuthorization(commitment: commitment, ticket: ticket))
    }

    func testPreparedEndpointRejectsCompatibilityAndRemoteHTTP() throws {
        let key = try GatewayPublicKey(rawRepresentation: Data(repeating: 1, count: 32))
        struct Noop: PreparedGatewayTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw ZKLLMGatewayError.protocolViolation("not called")
            }
        }
        XCTAssertThrowsError(try PreparedGatewayClient(
            inferURL: URL(string: "https://example.test/v1/chat/completions")!,
            gatewayPublicKey: key,
            transport: Noop()
        ))
        XCTAssertThrowsError(try PreparedGatewayClient(
            inferURL: URL(string: "http://example.test/v1/infer")!,
            gatewayPublicKey: key,
            transport: Noop()
        ))
        XCTAssertNoThrow(try PreparedGatewayClient(
            inferURL: URL(string: "http://127.0.0.1:8080/v1/infer")!,
            gatewayPublicKey: key,
            transport: Noop()
        ))
    }
}
