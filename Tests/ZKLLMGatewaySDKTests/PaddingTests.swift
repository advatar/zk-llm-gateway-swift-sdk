import XCTest
@testable import ZKLLMGatewaySDK

final class PaddingTests: XCTestCase {
    func testPadAndUnpadRoundTrip() throws {
        let payload = Data("hello world".utf8)
        let padded = try padPayload(payload, targetLength: 1024)

        XCTAssertEqual(padded.count, 1024)
        XCTAssertEqual(try unpadPayload(padded), payload)
    }
}
