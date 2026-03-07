import XCTest
@testable import ZKLLMGatewaySDK

final class RedactionTests: XCTestCase {
    func testRedactsAndRehydratesText() {
        let redactor = Redactor(mode: .stablePerValue)
        let input = "Contact alice@example.com and use sk-abcdef0123456789 for auth."

        let result = redactor.redactText(input)

        XCTAssertFalse(result.redacted.contains("alice@example.com"))
        XCTAssertFalse(result.redacted.contains("sk-abcdef0123456789"))
        XCTAssertEqual(redactor.rehydrateText(result.redacted, map: result.map), input)
    }

    func testStableModeUsesSingleMapEntryForRepeatedValues() {
        let redactor = Redactor(mode: .stablePerValue)
        let input = "alice@example.com alice@example.com"

        let result = redactor.redactText(input)

        XCTAssertEqual(result.map.count, 1)
        XCTAssertEqual(redactor.rehydrateText(result.redacted, map: result.map), input)
    }
}
