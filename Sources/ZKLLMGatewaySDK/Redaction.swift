import CryptoKit
import Foundation

public enum RedactionMode: String, Codable, Sendable {
    case stablePerValue = "stable_per_value"
    case ephemeral = "ephemeral"
}

public struct RedactionResult<Value: Sendable>: Sendable {
    public let redacted: Value
    public let map: [String: String]

    public init(redacted: Value, map: [String: String]) {
        self.redacted = redacted
        self.map = map
    }
}

private enum RedactionKind: String {
    case email = "EMAIL"
    case phone = "PHONE"
    case eth = "ETH"
    case apiKey = "APIKEY"
    case privateKey = "PRIVKEY"
    case term = "TERM"
}

public final class Redactor {
    public let mode: RedactionMode

    private let salt: Data
    private var customTerms: [String]
    private let patterns: [(kind: RedactionKind, regex: NSRegularExpression)]

    public init(mode: RedactionMode = .stablePerValue) {
        self.mode = mode
        self.salt = Data((0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        self.customTerms = []
        self.patterns = [
            (
                .privateKey,
                try! NSRegularExpression(
                    pattern: "-----BEGIN[\\s\\S]*?PRIVATE KEY-----[\\s\\S]*?-----END[\\s\\S]*?PRIVATE KEY-----",
                    options: []
                )
            ),
            (
                .apiKey,
                try! NSRegularExpression(
                    pattern: "\\b(sk-[A-Za-z0-9]{16,})\\b",
                    options: []
                )
            ),
            (
                .eth,
                try! NSRegularExpression(
                    pattern: "\\b0x[a-fA-F0-9]{40}\\b",
                    options: []
                )
            ),
            (
                .email,
                try! NSRegularExpression(
                    pattern: "\\b[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\\.)+[A-Z]{2,}\\b",
                    options: [.caseInsensitive]
                )
            ),
            (
                .phone,
                try! NSRegularExpression(
                    pattern: "(?<!\\w)\\+?(?:[0-9][0-9(). \\-]*){7,}[0-9](?!\\w)",
                    options: []
                )
            ),
        ]
    }

    public func addCustomTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customTerms.append(trimmed)
    }

    public func redactText(_ input: String) -> RedactionResult<String> {
        var output = input
        var mapping: [String: String] = [:]
        var counter = 0

        for term in customTerms where !term.isEmpty && output.contains(term) {
            let placeholder = makePlaceholder(kind: .term, original: term, counter: counter)
            output = output.replacingOccurrences(of: term, with: placeholder)
            mapping[placeholder] = term
            counter += 1
        }

        for (kind, regex) in patterns {
            while let match = regex.firstMatch(
                in: output,
                options: [],
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            ) {
                guard let range = Range(match.range, in: output) else {
                    break
                }

                let original = String(output[range])
                let placeholder = makePlaceholder(kind: kind, original: original, counter: counter)
                output.replaceSubrange(range, with: placeholder)
                mapping[placeholder] = original
                counter += 1
            }
        }

        return RedactionResult(redacted: output, map: mapping)
    }

    public func redactJSON(_ value: JSONValue) -> RedactionResult<JSONValue> {
        var mapping: [String: String] = [:]
        let redacted = redactJSON(value, mapping: &mapping)
        return RedactionResult(redacted: redacted, map: mapping)
    }

    public func rehydrateText(_ input: String, map: [String: String]) -> String {
        var output = input
        for key in map.keys.sorted(by: { $0.count > $1.count }) {
            if let original = map[key] {
                output = output.replacingOccurrences(of: key, with: original)
            }
        }
        return output
    }

    public func rehydrateJSON(_ value: JSONValue, map: [String: String]) -> JSONValue {
        switch value {
        case let .string(text):
            return .string(rehydrateText(text, map: map))
        case let .array(items):
            return .array(items.map { rehydrateJSON($0, map: map) })
        case let .object(object):
            return .object(object.mapValues { rehydrateJSON($0, map: map) })
        case .number, .bool, .null:
            return value
        }
    }

    private func redactJSON(_ value: JSONValue, mapping: inout [String: String]) -> JSONValue {
        switch value {
        case let .string(text):
            let result = redactText(text)
            for (key, original) in result.map {
                mapping[key] = original
            }
            return .string(result.redacted)
        case let .array(items):
            return .array(items.map { redactJSON($0, mapping: &mapping) })
        case let .object(object):
            return .object(object.mapValues { redactJSON($0, mapping: &mapping) })
        case .number, .bool, .null:
            return value
        }
    }

    private func makePlaceholder(kind: RedactionKind, original: String, counter: Int) -> String {
        var input = Data()
        input.append(salt)
        input.append(Data(kind.rawValue.utf8))

        switch mode {
        case .stablePerValue:
            input.append(Data(original.utf8))
        case .ephemeral:
            var counterLE = UInt64(counter).littleEndian
            withUnsafeBytes(of: &counterLE) { rawBuffer in
                input.append(contentsOf: rawBuffer)
            }
            input.append(Data(original.utf8))
        }

        let digest = SHA256.hash(data: input)
        let shortHex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "<\(kind.rawValue)_\(shortHex)>"
    }
}
