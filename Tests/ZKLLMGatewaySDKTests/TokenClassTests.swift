import XCTest
@testable import ZKLLMGatewaySDK

final class TokenClassTests: XCTestCase {
    func testParsingAndSizingTable() throws {
        XCTAssertEqual(try TokenClass(parsing: "2048"), .c2048)
        XCTAssertEqual(try TokenClass(parsing: "c512"), .c512)
        XCTAssertEqual(TokenClass.c1024.requestPaddedLength, 20 * 1024)
        XCTAssertEqual(TokenClass.c4096.responsePaddedLength, 128 * 1024)
        XCTAssertEqual(TokenClass.c256.maxOutputTokensHint, 256)
    }
}
