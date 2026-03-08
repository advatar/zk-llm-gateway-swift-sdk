import Foundation

public struct GatewayClientConfig: Sendable {
    public var inferPath: String
    public var authBearer: String?
    public var headers: [String: String]
    public var timeout: TimeInterval

    public init(
        inferPath: String = "/v1/infer",
        authBearer: String? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 60
    ) {
        self.inferPath = inferPath
        self.authBearer = authBearer
        self.headers = headers
        self.timeout = timeout
    }
}

public final class GatewayClient {
    public let endpoint: URL
    public let gatewayPublicKey: GatewayPublicKey
    public let tickets: any TicketSource
    public let config: GatewayClientConfig
    public let urlSession: URLSession
    public let inferURL: URL

    public init(
        endpoint: URL,
        gatewayPublicKey: GatewayPublicKey,
        tickets: any TicketSource,
        config: GatewayClientConfig = GatewayClientConfig(),
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.gatewayPublicKey = gatewayPublicKey
        self.tickets = tickets
        self.config = config
        self.urlSession = urlSession
        self.inferURL = joinURL(base: endpoint, path: config.inferPath)
    }

    public convenience init(
        endpoint: String,
        gatewayPublicKey: GatewayPublicKey,
        tickets: any TicketSource,
        config: GatewayClientConfig = GatewayClientConfig(),
        urlSession: URLSession = .shared
    ) throws {
        guard let url = URL(string: endpoint) else {
            throw ZKLLMGatewayError.protocolViolation("invalid endpoint URL: \(endpoint)")
        }

        self.init(
            endpoint: url,
            gatewayPublicKey: gatewayPublicKey,
            tickets: tickets,
            config: config,
            urlSession: urlSession
        )
    }

    public func inferJSON(tokenClass: TokenClass, upstream: ChatCompletionsRequest) async throws -> JSONValue {
        let ticket = try await tickets.nextTicket(tokenClass: tokenClass)
        return try await inferJSONWithTicket(tokenClass: tokenClass, ticket: ticket, upstream: upstream)
    }

    public func inferJSON(tokenClass: TokenClass, upstream: JSONValue) async throws -> JSONValue {
        let ticket = try await tickets.nextTicket(tokenClass: tokenClass)
        return try await inferJSONWithTicket(tokenClass: tokenClass, ticket: ticket, upstream: upstream)
    }

    public func inferJSONWithTicket(
        tokenClass: TokenClass,
        ticket: ZkTicket,
        upstream: ChatCompletionsRequest
    ) async throws -> JSONValue {
        try await inferJSONWithTicket(
            tokenClass: tokenClass,
            ticket: ticket,
            upstream: upstream.toJSONValue()
        )
    }

    public func inferJSONWithTicket(
        tokenClass: TokenClass,
        ticket: ZkTicket,
        upstream: JSONValue
    ) async throws -> JSONValue {
        guard ticket.tokenClass == tokenClass else {
            throw ZKLLMGatewayError.protocolViolation("ticket token_class must match requested token_class")
        }

        let chatRequest = try parseChatRequest(from: upstream)
        let payload = try buildInferenceRequest(tokenClass: tokenClass, ticket: ticket, request: chatRequest)

        let sealed = try sealJSON(
            gatewayPublicKey: gatewayPublicKey,
            tokenClass: tokenClass,
            payload: payload
        )

        var request = URLRequest(url: inferURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONEncoder().encode(sealed.envelope)

        var headers: [String: String] = [
            "accept": "application/json",
            "content-type": "application/json",
        ]

        for (key, value) in config.headers {
            headers[key] = value
        }

        if let bearer = config.authBearer {
            headers["authorization"] = "Bearer \(bearer)"
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (responseData, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200

        let responseEnvelope: Envelope
        do {
            responseEnvelope = try JSONDecoder().decode(Envelope.self, from: responseData)
        } catch {
            let snippet = String(decoding: responseData.prefix(500), as: UTF8.self)
            throw ZKLLMGatewayError.protocolViolation("failed to parse envelope (HTTP \(statusCode)): \(snippet)")
        }

        let decrypted = try openJSON(responseEnvelope, state: sealed.state)

        if let payload = try parseGatewayPayload(from: decrypted) {
            switch payload {
            case let .ok(response):
                return try JSONValue.fromEncodable(response)
            case let .err(error):
                throw ZKLLMGatewayError.gateway(
                    code: error.code ?? "gateway_error",
                    message: error.message ?? "unknown error"
                )
            }
        }

        if let errorObject = decrypted["error"]?.objectValue {
            throw ZKLLMGatewayError.gateway(
                code: errorObject["code"]?.stringValue ?? "gateway_error",
                message: errorObject["message"]?.stringValue ?? "unknown error"
            )
        }

        if !(200..<300).contains(statusCode) {
            throw ZKLLMGatewayError.http(statusCode: statusCode, message: "gateway returned HTTP \(statusCode)")
        }

        if let upstreamValue = decrypted["upstream"] {
            return upstreamValue
        }

        throw ZKLLMGatewayError.protocolViolation("missing response payload in decrypted gateway response")
    }

    public func chatCompletions(
        tokenClass: TokenClass,
        request: ChatCompletionsRequest
    ) async throws -> ChatCompletionsResponse {
        var effectiveRequest = request
        if effectiveRequest.maxTokens == nil {
            effectiveRequest.maxTokens = tokenClass.maxOutputTokensHint
        }

        let responseJSON = try await inferJSON(tokenClass: tokenClass, upstream: effectiveRequest)

        if let object = responseJSON.objectValue,
           object["output"]?.stringValue != nil,
           object["request_id"]?.stringValue != nil {
            let inferenceResponse = try responseJSON.decode(InferenceResponse.self)
            if let upstream = inferenceResponse.upstream {
                let body = upstream["body"] ?? upstream
                if body.objectValue != nil {
                    var response = try body.decode(ChatCompletionsResponse.self)
                    response.extra["billed_token_class"] = .string(inferenceResponse.billedTokenClass.rawValue)
                    response.id = response.id ?? inferenceResponse.requestID
                    response.model = response.model ?? inferenceResponse.model
                    return response
                }
            }

            return ChatCompletionsResponse(
                id: inferenceResponse.requestID,
                model: inferenceResponse.model,
                choices: [
                    ChatChoice(
                        index: 0,
                        message: .assistant(inferenceResponse.output),
                        finishReason: "stop"
                    ),
                ],
                extra: [
                    "billed_token_class": .string(inferenceResponse.billedTokenClass.rawValue),
                ]
            )
        }

        let body = responseJSON["body"] ?? responseJSON
        guard body.objectValue != nil else {
            throw ZKLLMGatewayError.protocolViolation("unexpected upstream response type")
        }

        return try body.decode(ChatCompletionsResponse.self)
    }
}

private enum GatewayEnvelopePayload {
    case ok(InferenceResponse)
    case err(ErrorResponse)
}

private struct InferenceRequest: Encodable, Sendable {
    let requestID: String
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int?
    let temperature: Double?
    let stream: Bool?
    let tokenClass: TokenClass
    let ticket: ZkTicket
    let extra: [String: JSONValue]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(requestID, forKey: AnyCodingKey("request_id"))
        try container.encode(model, forKey: AnyCodingKey("model"))
        try container.encode(messages, forKey: AnyCodingKey("messages"))
        try container.encodeIfPresent(maxTokens, forKey: AnyCodingKey("max_tokens"))
        try container.encodeIfPresent(temperature, forKey: AnyCodingKey("temperature"))
        try container.encodeIfPresent(stream, forKey: AnyCodingKey("stream"))
        try container.encode(tokenClass, forKey: AnyCodingKey("token_class"))
        try container.encode(ticket, forKey: AnyCodingKey("ticket"))

        for (key, value) in extra {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

private struct InferenceResponse: Codable, Sendable {
    let requestID: String
    let model: String
    let output: String
    let billedTokenClass: TokenClass
    let upstream: JSONValue?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case model
        case output
        case billedTokenClass = "billed_token_class"
        case upstream
    }
}

private struct ErrorResponse: Codable, Sendable {
    let requestID: String?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case code
        case message
    }
}

private func joinURL(base: URL, path: String) -> URL {
    let baseString = base.absoluteString.hasSuffix("/") ? base.absoluteString : "\(base.absoluteString)/"
    let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    let baseURL = URL(string: baseString) ?? base
    return URL(string: normalizedPath, relativeTo: baseURL)?.absoluteURL ?? base.appendingPathComponent(normalizedPath)
}

private func parseChatRequest(from upstream: JSONValue) throws -> ChatCompletionsRequest {
    if let object = upstream.objectValue,
       object["model"]?.stringValue != nil,
       object["messages"]?.arrayValue != nil {
        do {
            return try upstream.decode(ChatCompletionsRequest.self)
        } catch {
            throw ZKLLMGatewayError.protocolViolation("invalid chat request payload: \(error.localizedDescription)")
        }
    }

    if let object = upstream.objectValue,
       object["path"]?.stringValue == "/v1/chat/completions",
       let body = object["body"] {
        return try parseChatRequest(from: body)
    }

    throw ZKLLMGatewayError.protocolViolation(
        "unsupported inferJSON payload; expected chat request body or {path:'/v1/chat/completions', body:{...}}"
    )
}

private func buildInferenceRequest(
    tokenClass: TokenClass,
    ticket: ZkTicket,
    request: ChatCompletionsRequest
) throws -> InferenceRequest {
    if request.stream == true {
        throw ZKLLMGatewayError.protocolViolation("stream=true is not supported on /v1/infer")
    }

    let extra = request.extra.filter { key, _ in
        !["request_id", "token_class", "ticket"].contains(key)
    }

    return InferenceRequest(
        requestID: UUID().uuidString.lowercased(),
        model: request.model,
        messages: request.messages,
        maxTokens: request.maxTokens,
        temperature: request.temperature,
        stream: request.stream,
        tokenClass: tokenClass,
        ticket: ticket,
        extra: extra
    )
}

private func parseGatewayPayload(from decrypted: JSONValue) throws -> GatewayEnvelopePayload? {
    guard let object = decrypted.objectValue,
          let kind = object["kind"]?.stringValue
    else {
        return nil
    }

    switch kind {
    case "ok":
        guard let response = object["response"] else { return nil }
        return .ok(try response.decode(InferenceResponse.self))
    case "err":
        guard let error = object["error"] else { return nil }
        return .err(try error.decode(ErrorResponse.self))
    default:
        return nil
    }
}
