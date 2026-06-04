import XCTest
@testable import ZKLLMGatewaySDK

final class PaddingTests: XCTestCase {
    func testPadAndUnpadRoundTrip() throws {
        let payload = Data("hello world".utf8)
        let padded = try padPayload(payload, targetLength: 1024)

        XCTAssertEqual(padded.count, 1024)
        XCTAssertEqual(try unpadPayload(padded), payload)
    }

    func testSharedPaddingVector() throws {
        let padded = try padPayload(Data("{\"x\":1}".utf8), targetLength: 16)
        XCTAssertEqual(
            Array(padded),
            [0x7b, 0x22, 0x78, 0x22, 0x3a, 0x31, 0x7d, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(try unpadPayload(padded), Data("{\"x\":1}".utf8))
    }
}
