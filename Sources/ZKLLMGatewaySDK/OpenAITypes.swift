import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }

    public static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content)
    }
}

public struct ChatCompletionsRequest: Codable, Equatable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool?
    public var extra: [String: JSONValue]

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        model = try container.decode(String.self, forKey: AnyCodingKey("model"))
        messages = try container.decode([ChatMessage].self, forKey: AnyCodingKey("messages"))
        temperature = try container.decodeIfPresent(Double.self, forKey: AnyCodingKey("temperature"))
        maxTokens = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("max_tokens"))
        stream = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("stream"))

        let known = Set(["model", "messages", "temperature", "max_tokens", "stream"])
        var extraFields: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = extraFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)

        try container.encode(model, forKey: AnyCodingKey("model"))
        try container.encode(messages, forKey: AnyCodingKey("messages"))
        try container.encodeIfPresent(temperature, forKey: AnyCodingKey("temperature"))
        try container.encodeIfPresent(maxTokens, forKey: AnyCodingKey("max_tokens"))
        try container.encodeIfPresent(stream, forKey: AnyCodingKey("stream"))

        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }

    public func toJSONValue() -> JSONValue {
        .object(
            [
                "model": .string(model),
                "messages": .array(messages.map { .object(["role": .string($0.role), "content": .string($0.content)]) }),
            ]
            .merging(temperature.map { ["temperature": .number($0)] } ?? [:], uniquingKeysWith: { _, new in new })
            .merging(maxTokens.map { ["max_tokens": .number(Double($0))] } ?? [:], uniquingKeysWith: { _, new in new })
            .merging(stream.map { ["stream": .bool($0)] } ?? [:], uniquingKeysWith: { _, new in new })
            .merging(extra, uniquingKeysWith: { _, new in new })
        )
    }
}

public struct Usage: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var extra: [String: JSONValue]

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("prompt_tokens"))
        completionTokens = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("completion_tokens"))
        totalTokens = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("total_tokens"))

        let known = Set(["prompt_tokens", "completion_tokens", "total_tokens"])
        var extraFields: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = extraFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(promptTokens, forKey: AnyCodingKey("prompt_tokens"))
        try container.encodeIfPresent(completionTokens, forKey: AnyCodingKey("completion_tokens"))
        try container.encodeIfPresent(totalTokens, forKey: AnyCodingKey("total_tokens"))

        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

public struct ChatChoice: Codable, Equatable, Sendable {
    public var index: Int
    public var message: ChatMessage?
    public var finishReason: String?
    public var extra: [String: JSONValue]

    public init(
        index: Int,
        message: ChatMessage? = nil,
        finishReason: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        index = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("index")) ?? 0
        message = try container.decodeIfPresent(ChatMessage.self, forKey: AnyCodingKey("message"))
        finishReason = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("finish_reason"))

        let known = Set(["index", "message", "finish_reason"])
        var extraFields: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = extraFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(index, forKey: AnyCodingKey("index"))
        try container.encodeIfPresent(message, forKey: AnyCodingKey("message"))
        try container.encodeIfPresent(finishReason, forKey: AnyCodingKey("finish_reason"))

        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

public struct ChatCompletionsResponse: Codable, Equatable, Sendable {
    public var id: String?
    public var model: String?
    public var choices: [ChatChoice]
    public var usage: Usage?
    public var extra: [String: JSONValue]

    public init(
        id: String? = nil,
        model: String? = nil,
        choices: [ChatChoice],
        usage: Usage? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.model = model
        self.choices = choices
        self.usage = usage
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("id"))
        model = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("model"))
        choices = try container.decodeIfPresent([ChatChoice].self, forKey: AnyCodingKey("choices")) ?? []
        usage = try container.decodeIfPresent(Usage.self, forKey: AnyCodingKey("usage"))

        let known = Set(["id", "model", "choices", "usage"])
        var extraFields: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = extraFields
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encodeIfPresent(id, forKey: AnyCodingKey("id"))
        try container.encodeIfPresent(model, forKey: AnyCodingKey("model"))
        try container.encode(choices, forKey: AnyCodingKey("choices"))
        try container.encodeIfPresent(usage, forKey: AnyCodingKey("usage"))

        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }

    public func firstText() -> String? {
        for choice in choices {
            if let content = choice.message?.content {
                return content
            }
        }
        return nil
    }
}
