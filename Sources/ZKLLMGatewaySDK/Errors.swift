import Foundation

public enum ZKLLMGatewayError: Error, Equatable, LocalizedError, Sendable {
    case invalidTokenClass(String)
    case invalidGatewayPublicKey(String)
    case base64(String)
    case crypto(String)
    case protocolViolation(String)
    case http(statusCode: Int, message: String)
    case gateway(code: String, message: String)
    case invalidPadding(String)
    case payloadTooLarge(actual: Int, limit: Int)
    case ticketExhausted(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTokenClass(message),
             let .invalidGatewayPublicKey(message),
             let .base64(message),
             let .crypto(message),
             let .protocolViolation(message),
             let .invalidPadding(message),
             let .ticketExhausted(message):
            return message
        case let .http(_, message),
             let .gateway(_, message):
            return message
        case let .payloadTooLarge(actual, limit):
            return "payload too large: \(actual) > \(limit)"
        }
    }
}
