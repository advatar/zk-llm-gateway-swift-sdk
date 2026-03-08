import Foundation

public enum GatewayPaths {
    public static let infer = "/v1/infer"
    public static let relay = "/relay"
}

public enum TicketSourceConfig: Sendable, Equatable {
    case dummy
    case file(path: String)

    func load() throws -> any TicketSource {
        switch self {
        case .dummy:
            return DummyTicketSource()
        case let .file(path):
            return try FileTicketSource(path: path)
        }
    }
}

public struct AppGatewayConfig: Sendable {
    public var endpoint: URL
    public var inferPath: String
    public var gatewayPublicKey: GatewayPublicKey
    public var authBearer: String?
    public var tickets: TicketSourceConfig
    public var model: String
    public var tokenClass: TokenClass
    public var temperature: Double?
    public var timeout: TimeInterval

    public init(
        endpoint: URL,
        gatewayPublicKey: GatewayPublicKey,
        tickets: TicketSourceConfig,
        model: String,
        tokenClass: TokenClass,
        inferPath: String = GatewayPaths.infer,
        authBearer: String? = nil,
        temperature: Double? = nil,
        timeout: TimeInterval = 60
    ) {
        self.endpoint = endpoint
        self.inferPath = inferPath
        self.gatewayPublicKey = gatewayPublicKey
        self.authBearer = authBearer
        self.tickets = tickets
        self.model = model
        self.tokenClass = tokenClass
        self.temperature = temperature
        self.timeout = timeout
    }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppGatewayConfig {
        let endpointRaw = try requiredEnv(env, keys: ["GATEWAY_BASE_URL", "GATEWAY_URL"])
        guard let endpoint = URL(string: endpointRaw) else {
            throw ZKLLMGatewayError.protocolViolation("invalid endpoint URL: \(endpointRaw)")
        }

        let pkB64 = try requiredEnv(env, keys: ["GATEWAY_PUBLIC_KEY_B64"])
        let gatewayPublicKey = try GatewayPublicKey(base64: pkB64)

        let useRelay = try env["GATEWAY_USE_RELAY"].map {
            try parseBool($0, key: "GATEWAY_USE_RELAY")
        } ?? false

        let inferPath = env["GATEWAY_INFER_PATH"] ?? (useRelay ? GatewayPaths.relay : GatewayPaths.infer)

        let tickets: TicketSourceConfig
        if let path = env["GATEWAY_TICKETS_JSON"] ?? env["TICKETS_JSON"], !path.isEmpty {
            tickets = .file(path: path)
        } else if let rawDummy = env["GATEWAY_USE_DUMMY_TICKETS"] {
            if try parseBool(rawDummy, key: "GATEWAY_USE_DUMMY_TICKETS") {
                tickets = .dummy
            } else {
                throw ZKLLMGatewayError.protocolViolation(
                    "set GATEWAY_TICKETS_JSON or GATEWAY_USE_DUMMY_TICKETS=true"
                )
            }
        } else {
            throw ZKLLMGatewayError.protocolViolation(
                "set GATEWAY_TICKETS_JSON or GATEWAY_USE_DUMMY_TICKETS=true"
            )
        }

        let model = env["GATEWAY_MODEL"] ?? env["MODEL"] ?? "gpt-4o-mini"
        let tokenClass = try (env["GATEWAY_TOKEN_CLASS"] ?? env["TOKEN_CLASS"]).map(TokenClass.init(parsing:)) ?? .c2048
        let temperature = try env["GATEWAY_TEMPERATURE"].map {
            try parseDouble($0, key: "GATEWAY_TEMPERATURE")
        }
        let timeout = try env["GATEWAY_TIMEOUT_SECS"].map {
            try parseDouble($0, key: "GATEWAY_TIMEOUT_SECS")
        } ?? 60

        return AppGatewayConfig(
            endpoint: endpoint,
            gatewayPublicKey: gatewayPublicKey,
            tickets: tickets,
            model: model,
            tokenClass: tokenClass,
            inferPath: inferPath,
            authBearer: env["GATEWAY_AUTH_BEARER"],
            temperature: temperature,
            timeout: timeout
        )
    }

    public func withInferPath(_ inferPath: String) -> AppGatewayConfig {
        var copy = self
        copy.inferPath = inferPath
        return copy
    }

    public func useGatewayPath() -> AppGatewayConfig {
        withInferPath(GatewayPaths.infer)
    }

    public func useRelayPath() -> AppGatewayConfig {
        withInferPath(GatewayPaths.relay)
    }

    public func withAuthBearer(_ bearer: String) -> AppGatewayConfig {
        var copy = self
        copy.authBearer = bearer
        return copy
    }

    public func withTemperature(_ temperature: Double) -> AppGatewayConfig {
        var copy = self
        copy.temperature = temperature
        return copy
    }

    public func withTimeout(_ timeout: TimeInterval) -> AppGatewayConfig {
        var copy = self
        copy.timeout = timeout
        return copy
    }

    public func build() throws -> AppGateway {
        let client = GatewayClient(
            endpoint: endpoint,
            gatewayPublicKey: gatewayPublicKey,
            tickets: try tickets.load(),
            config: GatewayClientConfig(
                inferPath: inferPath,
                authBearer: authBearer,
                timeout: timeout
            )
        )

        return AppGateway(
            client: client,
            defaultModel: model,
            defaultTokenClass: tokenClass,
            defaultTemperature: temperature
        )
    }
}

public struct AppChatRequest: Equatable, Sendable {
    public var systemPrompt: String?
    public var messages: [ChatMessage]
    public var model: String?
    public var tokenClass: TokenClass?
    public var temperature: Double?

    public init(
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        model: String? = nil,
        tokenClass: TokenClass? = nil,
        temperature: Double? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.model = model
        self.tokenClass = tokenClass
        self.temperature = temperature
    }

    public static func fromUserPrompt(_ userPrompt: String) -> AppChatRequest {
        AppChatRequest(messages: [.user(userPrompt)])
    }

    public func withSystemPrompt(_ systemPrompt: String) -> AppChatRequest {
        var copy = self
        copy.systemPrompt = systemPrompt
        return copy
    }

    public func withModel(_ model: String) -> AppChatRequest {
        var copy = self
        copy.model = model
        return copy
    }

    public func withTokenClass(_ tokenClass: TokenClass) -> AppChatRequest {
        var copy = self
        copy.tokenClass = tokenClass
        return copy
    }

    public func withTemperature(_ temperature: Double) -> AppChatRequest {
        var copy = self
        copy.temperature = temperature
        return copy
    }
}

public struct AppGateway {
    public let client: GatewayClient
    public let defaultModel: String
    public let defaultTokenClass: TokenClass
    public let defaultTemperature: Double?

    public init(
        client: GatewayClient,
        defaultModel: String,
        defaultTokenClass: TokenClass,
        defaultTemperature: Double? = nil
    ) {
        self.client = client
        self.defaultModel = defaultModel
        self.defaultTokenClass = defaultTokenClass
        self.defaultTemperature = defaultTemperature
    }

    public func ask(_ userPrompt: String) async throws -> String {
        let response = try await chat(.fromUserPrompt(userPrompt))
        return response.firstText() ?? ""
    }

    public func askWithSystem(
        _ systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let response = try await chat(
            .fromUserPrompt(userPrompt).withSystemPrompt(systemPrompt)
        )
        return response.firstText() ?? ""
    }

    public func chat(_ request: AppChatRequest) async throws -> ChatCompletionsResponse {
        guard !request.messages.isEmpty else {
            throw ZKLLMGatewayError.protocolViolation(
                "chat request must include at least one message"
            )
        }

        var messages = request.messages
        if let systemPrompt = request.systemPrompt {
            messages.insert(.system(systemPrompt), at: 0)
        }

        return try await client.chatCompletions(
            tokenClass: request.tokenClass ?? defaultTokenClass,
            request: ChatCompletionsRequest(
                model: request.model ?? defaultModel,
                messages: messages,
                temperature: request.temperature ?? defaultTemperature,
                maxTokens: nil,
                stream: false
            )
        )
    }
}

private func requiredEnv(_ env: [String: String], keys: [String]) throws -> String {
    for key in keys {
        if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
    }
    throw ZKLLMGatewayError.protocolViolation(
        "missing environment variable; set one of \(keys.joined(separator: ", "))"
    )
}

private func parseBool(_ raw: String, key: String) throws -> Bool {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
        true
    case "0", "false", "no", "off":
        false
    default:
        throw ZKLLMGatewayError.protocolViolation(
            "\(key) must be one of true/false/1/0/yes/no/on/off"
        )
    }
}

private func parseDouble(_ raw: String, key: String) throws -> Double {
    guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ZKLLMGatewayError.protocolViolation("\(key) must be numeric")
    }
    return value
}
