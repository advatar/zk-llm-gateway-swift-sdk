import Foundation

public enum TokenClass: String, Codable, CaseIterable, Sendable {
    case c256
    case c512
    case c1024
    case c2048
    case c4096

    public init(parsing value: String) throws {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "c256", "256":
            self = .c256
        case "c512", "512":
            self = .c512
        case "c1024", "1024":
            self = .c1024
        case "c2048", "2048":
            self = .c2048
        case "c4096", "4096":
            self = .c4096
        default:
            throw ZKLLMGatewayError.invalidTokenClass("invalid token class: \(value)")
        }
    }

    public var maxPromptBytes: Int {
        switch self {
        case .c256:
            2 * 1024
        case .c512:
            4 * 1024
        case .c1024:
            8 * 1024
        case .c2048:
            16 * 1024
        case .c4096:
            32 * 1024
        }
    }

    public var requestPaddedLength: Int {
        switch self {
        case .c256:
            8 * 1024
        case .c512:
            12 * 1024
        case .c1024:
            20 * 1024
        case .c2048:
            36 * 1024
        case .c4096:
            68 * 1024
        }
    }

    public var responsePaddedLength: Int {
        switch self {
        case .c256:
            8 * 1024
        case .c512:
            16 * 1024
        case .c1024:
            32 * 1024
        case .c2048:
            64 * 1024
        case .c4096:
            128 * 1024
        }
    }

    public var maxOutputTokensHint: Int {
        switch self {
        case .c256:
            256
        case .c512:
            512
        case .c1024:
            1024
        case .c2048:
            2048
        case .c4096:
            4096
        }
    }
}

extension TokenClass {
    var id: UInt8 {
        switch self {
        case .c256:
            1
        case .c512:
            2
        case .c1024:
            3
        case .c2048:
            4
        case .c4096:
            5
        }
    }
}
