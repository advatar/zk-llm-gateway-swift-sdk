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

    func testFileTicketSourcePersistsConsumptionAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let ticketJSON = """
        [
          {
            "nullifier": "Zmlyc3Q=",
            "proof": "",
            "token_class": "c2048"
          },
          {
            "nullifier": "c2Vjb25k",
            "proof": "",
            "token_class": "c2048"
          }
        ]
        """
        try Data(ticketJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let firstSource = try FileTicketSource(path: url.path)
        let first = try await firstSource.nextTicket(tokenClass: .c2048)
        XCTAssertEqual(first.nullifier, "Zmlyc3Q=")

        let secondSource = try FileTicketSource(path: url.path)
        let second = try await secondSource.nextTicket(tokenClass: .c2048)
        XCTAssertEqual(second.nullifier, "c2Vjb25k")

        let remaining = await secondSource.remaining()
        XCTAssertEqual(remaining, 0)
    }

    func testFileTicketSourceAppendsPurchasedTickets() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try Data("[]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try FileTicketSource(path: url.path)
        try await source.appendTickets([
            ZkTicket(
                commitmentRoot: "cmVjZWlwdC1yb290",
                nullifier: "cHVyY2hhc2Vk",
                tokenClass: .c512,
                proof: "cHJvb2Y="
            )
        ])

        let reloaded = try FileTicketSource(path: url.path)
        let ticket = try await reloaded.nextTicket(tokenClass: .c512)
        XCTAssertEqual(ticket.nullifier, "cHVyY2hhc2Vk")
        XCTAssertEqual(ticket.tokenClass, .c512)
    }
}
