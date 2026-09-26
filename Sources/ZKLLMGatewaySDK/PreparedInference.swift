import Foundation

/// Immutable request snapshot prepared before payment authorization.
///
/// This type intentionally exposes the canonical authorization projection bytes rather than
/// implementing SHAKE256 inside the Swift SDK. The injected authorization provider must use
/// the gateway/Actum canonical commitment implementation and return both the resulting
/// 48-byte commitment and the ticket bound to it.
public struct PreparedInference: Sendable {
    public let requestID: String
    public let tokenClass: TokenClass
    public let model: String
    public let canonicalAuthorizationProjection: Data

    let requestWithoutTicket: JSONValue

    public static func prepare(
        tokenClass: TokenClass,
        request: ChatCompletionsRequest,
        requestID: UUID = UUID()
    ) throws -> PreparedInference {
        if request.stream == true {
            throw ZKLLMGatewayError.protocolViolation("stream=true is not supported on /v1/infer")
        }
        try validatePreparedOptions(request.extra)
        if let temperature = request.temperature,
           ![0.0, 0.5, 1.0, 1.5, 2.0].contains(temperature) {
            throw ZKLLMGatewayError.protocolViolation("temperature is not in the qualified canonical subset")
        }
        let id = requestID.uuidString.lowercased()
        let messages = try JSONValue.fromEncodable(request.messages)
        let options = request.extra
        let projection: JSONValue = .object([
            "request_id": .string(id),
            "model": .string(request.model),
            "messages": messages,
            "max_tokens": request.maxTokens.map { .number(Double($0)) } ?? .null,
            "temperature": request.temperature.map { .number($0) } ?? .null,
            "stream": request.stream.map { .bool($0) } ?? .null,
            "token_class": .string(tokenClass.rawValue),
            "provider_options": .object(options),
        ])
        let canonical = try canonicalJSONData(projection)
        var wire: [String: JSONValue] = [
            "request_id": .string(id),
            "model": .string(request.model),
            "messages": messages,
            "token_class": .string(tokenClass.rawValue),
        ]
        if let maxTokens = request.maxTokens { wire["max_tokens"] = .number(Double(maxTokens)) }
        if let temperature = request.temperature { wire["temperature"] = .number(temperature) }
        if let stream = request.stream { wire["stream"] = .bool(stream) }
        for (key, value) in options { wire[key] = value }
        return .init(
            requestID: id,
            tokenClass: tokenClass,
            model: request.model,
            canonicalAuthorizationProjection: canonical,
            requestWithoutTicket: .object(wire)
        )
    }

    public func authorize(using provider: any PreparedAuthorizationProviding) async throws -> AuthorizedPreparedInference {
        let authorization = try await provider.authorize(self)
        return try AuthorizedPreparedInference(prepared: self, authorization: authorization)
    }
}

public struct PreparedAuthorization: Sendable {
    public let commitment: Data
    public let ticket: ZkTicket

    public init(commitment: Data, ticket: ZkTicket) throws {
        guard commitment.count == 48 else {
            throw ZKLLMGatewayError.protocolViolation("authorization commitment must be 48 bytes")
        }
        guard Data(base64Encoded: ticket.commitmentRoot) == commitment else {
            throw ZKLLMGatewayError.protocolViolation("ticket commitment_root does not match authorization commitment")
        }
        self.commitment = commitment
        self.ticket = ticket
    }
}

public protocol PreparedAuthorizationProviding: Sendable {
    func authorize(_ prepared: PreparedInference) async throws -> PreparedAuthorization
}

public struct AuthorizedPreparedInference: Sendable {
    public let prepared: PreparedInference
    public let authorization: PreparedAuthorization

    public init(prepared: PreparedInference, authorization: PreparedAuthorization) throws {
        guard authorization.ticket.tokenClass == prepared.tokenClass else {
            throw ZKLLMGatewayError.protocolViolation("ticket token_class must match prepared token_class")
        }
        self.prepared = prepared
        self.authorization = authorization
    }

    var payload: JSONValue {
        guard case .object(var object) = prepared.requestWithoutTicket else { return prepared.requestWithoutTicket }
        object["ticket"] = (try? JSONValue.fromEncodable(authorization.ticket)) ?? .null
        return .object(object)
    }
}

public protocol PreparedGatewayTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionPreparedGatewayTransport: PreparedGatewayTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ZKLLMGatewayError.protocolViolation("gateway response is not HTTP")
        }
        return (data, http)
    }
}

public struct PreparedGatewayClient: Sendable {
    public let inferURL: URL
    public let gatewayPublicKey: GatewayPublicKey
    public let timeout: TimeInterval
    private let transport: any PreparedGatewayTransport

    public init(
        inferURL: URL,
        gatewayPublicKey: GatewayPublicKey,
        timeout: TimeInterval = 60,
        transport: any PreparedGatewayTransport
    ) throws {
        guard inferURL.scheme == "https" || (inferURL.scheme == "http" && inferURL.host == "127.0.0.1") else {
            throw ZKLLMGatewayError.protocolViolation("prepared transport requires HTTPS or explicit numeric loopback HTTP")
        }
        guard inferURL.path == "/v1/infer" || inferURL.path == "/relay",
              inferURL.user == nil, inferURL.password == nil,
              inferURL.query == nil, inferURL.fragment == nil else {
            throw ZKLLMGatewayError.protocolViolation("prepared transport endpoint is not qualified")
        }
        guard timeout > 0, timeout <= 300 else {
            throw ZKLLMGatewayError.protocolViolation("prepared transport timeout is out of range")
        }
        self.inferURL = inferURL
        self.gatewayPublicKey = gatewayPublicKey
        self.timeout = timeout
        self.transport = transport
    }

    public func send(_ authorized: AuthorizedPreparedInference) async throws -> JSONValue {
        let sealed = try sealJSON(
            gatewayPublicKey: gatewayPublicKey,
            tokenClass: authorized.prepared.tokenClass,
            payload: authorized.payload
        )
        guard sealed.envelope.requestID == authorized.prepared.requestID else {
            throw ZKLLMGatewayError.protocolViolation("prepared request_id changed before transport")
        }
        var request = URLRequest(url: inferURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(sealed.envelope)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("identity", forHTTPHeaderField: "accept-encoding")

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw ZKLLMGatewayError.http(statusCode: response.statusCode, message: "gateway rejected prepared request")
        }
        guard data.count <= authorized.prepared.tokenClass.responsePaddedLength * 2 else {
            throw ZKLLMGatewayError.protocolViolation("gateway response exceeds qualified bound")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ZKLLMGatewayError.protocolViolation("gateway response envelope is invalid")
        }
        let decrypted = try openJSON(envelope, state: sealed.state)
        guard decrypted["kind"]?.stringValue == "ok",
              let responseObject = decrypted["response"]?.objectValue,
              responseObject["request_id"]?.stringValue == authorized.prepared.requestID,
              responseObject["model"]?.stringValue == authorized.prepared.model,
              responseObject["billed_token_class"]?.stringValue == authorized.prepared.tokenClass.rawValue else {
            throw ZKLLMGatewayError.protocolViolation("prepared response binding mismatch")
        }
        return .object(responseObject)
    }
}

private func validatePreparedOptions(_ options: [String: JSONValue]) throws {
    let forbidden = ["request_id", "token_class", "ticket", "provider_options", "max_completion_tokens",
                     "max_output_tokens", "api_key", "apiKey", "authorization"]
    if options.keys.contains(where: forbidden.contains) {
        throw ZKLLMGatewayError.protocolViolation("request contains a reserved or unqualified provider option")
    }
    if let n = options["n"], n.intValue != 1 {
        throw ZKLLMGatewayError.protocolViolation("only n=1 is qualified")
    }
    if let store = options["store"], store.boolValue != false {
        throw ZKLLMGatewayError.protocolViolation("provider storage must be explicitly false when supplied")
    }
    try options.values.forEach(validatePortableJSON)
}

private func validatePortableJSON(_ value: JSONValue) throws {
    switch value {
    case .null, .string, .bool:
        return
    case let .number(number):
        guard number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else {
            throw ZKLLMGatewayError.protocolViolation("provider option number is outside the qualified integer subset")
        }
    case let .array(values):
        try values.forEach(validatePortableJSON)
    case let .object(object):
        try object.values.forEach(validatePortableJSON)
    }
}

private func canonicalJSONData(_ value: JSONValue) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: value.toData(), options: [.fragmentsAllowed])
    guard JSONSerialization.isValidJSONObject(object) else {
        throw ZKLLMGatewayError.protocolViolation("authorization projection is not canonical JSON")
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
