import Foundation
import XCTest
@testable import ZKLLMGatewaySDK

final class TicketSourceTests: XCTestCase {
    func testFileTicketSourcePrefersExactMatchThenFallback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")

        let ticketJSON = """
        [
          {
            "nullifier": "Zmlyc3Q=",
            "proof": "",
            "token_class": "c2048"
          },
          {
            "nullifier": "ZmFsbGJhY2s="
          }
        ]
        """

        try Data(ticketJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try FileTicketSource(path: url.path)

        let first = try await source.nextTicket(tokenClass: .c2048)
        XCTAssertEqual(first.tokenClass, .c2048)
        XCTAssertEqual(first.nullifier, "Zmlyc3Q=")

        let second = try await source.nextTicket(tokenClass: .c512)
        XCTAssertEqual(second.tokenClass, .c512)
        XCTAssertEqual(second.nullifier, "ZmFsbGJhY2s=")

        let remaining = await source.remaining()
        XCTAssertEqual(remaining, 0)
    }
}
