import Foundation

public struct ZkTicket: Codable, Equatable, Sendable {
    public var commitmentRoot: String
    public var nullifier: String
    public var tokenClass: TokenClass
    public var proof: String

    enum CodingKeys: String, CodingKey {
        case commitmentRoot = "commitment_root"
        case nullifier
        case tokenClass = "token_class"
        case proof
    }

    public init(commitmentRoot: String, nullifier: String, tokenClass: TokenClass, proof: String) {
        self.commitmentRoot = commitmentRoot
        self.nullifier = nullifier
        self.tokenClass = tokenClass
        self.proof = proof
    }

    public static func randomDummy(tokenClass: TokenClass) -> ZkTicket {
        ZkTicket(
            commitmentRoot: randomBytes(count: 32).base64EncodedString(),
            nullifier: randomBytes(count: 32).base64EncodedString(),
            tokenClass: tokenClass,
            proof: randomBytes(count: 64).base64EncodedString()
        )
    }
}

public protocol TicketSource: Sendable {
    func nextTicket(tokenClass: TokenClass) async throws -> ZkTicket
}

public struct DummyTicketSource: TicketSource, Sendable {
    public init() {}

    public func nextTicket(tokenClass: TokenClass) async throws -> ZkTicket {
        ZkTicket.randomDummy(tokenClass: tokenClass)
    }
}

public actor FileTicketSource: TicketSource {
    private struct RawTicket: Sendable {
        var commitmentRoot: String?
        var commitmentRootB64: String?
        var nullifier: String?
        var nullifierB64: String?
        var tokenClass: String?
        var proof: String?
        var proofB64: String?

        init?(jsonValue: JSONValue) {
            guard case let .object(object) = jsonValue else {
                return nil
            }

            commitmentRoot = object["commitment_root"]?.stringValue
            commitmentRootB64 = object["commitment_root_b64"]?.stringValue
            nullifier = object["nullifier"]?.stringValue
            nullifierB64 = object["nullifier_b64"]?.stringValue
            tokenClass = object["token_class"]?.stringValue
            proof = object["proof"]?.stringValue
            proofB64 = object["proof_b64"]?.stringValue
        }
    }

    private var tickets: [RawTicket]

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let json = try JSONValue.fromData(data)
        let rawTickets = json.arrayValue?.compactMap(RawTicket.init(jsonValue:)) ?? []
        self.tickets = rawTickets
    }

    public init(url: URL) throws {
        try self.init(path: url.path)
    }

    public func remaining() -> Int {
        tickets.count
    }

    public func nextTicket(tokenClass: TokenClass) async throws -> ZkTicket {
        var exactIndex: Int?
        var fallbackIndex: Int?

        for (index, ticket) in tickets.enumerated() {
            guard let rawTokenClass = ticket.tokenClass else {
                if fallbackIndex == nil {
                    fallbackIndex = index
                }
                continue
            }

            guard let parsedTokenClass = try? TokenClass(parsing: rawTokenClass) else {
                continue
            }

            if parsedTokenClass == tokenClass {
                exactIndex = index
                break
            }
        }

        guard let index = exactIndex ?? fallbackIndex else {
            throw ZKLLMGatewayError.ticketExhausted("ticket pool exhausted")
        }

        let raw = tickets.remove(at: index)

        do {
            let normalized = try normalize(rawTicket: raw, fallbackTokenClass: tokenClass)
            guard normalized.tokenClass == tokenClass else {
                throw ZKLLMGatewayError.ticketExhausted("ticket token_class mismatch")
            }
            return normalized
        } catch let error as ZKLLMGatewayError {
            switch error {
            case .ticketExhausted:
                throw error
            default:
                throw ZKLLMGatewayError.ticketExhausted("invalid ticket entry: \(error.localizedDescription)")
            }
        } catch {
            throw ZKLLMGatewayError.ticketExhausted("invalid ticket entry: \(error.localizedDescription)")
        }
    }

    private func normalize(rawTicket: RawTicket, fallbackTokenClass: TokenClass) throws -> ZkTicket {
        let commitmentRoot = rawTicket.commitmentRoot
            ?? rawTicket.commitmentRootB64
            ?? Data(repeating: 0, count: 32).base64EncodedString()

        guard let nullifier = rawTicket.nullifier ?? rawTicket.nullifierB64, !nullifier.isEmpty else {
            throw ZKLLMGatewayError.ticketExhausted("ticket missing nullifier/nullifier_b64")
        }

        let proof = rawTicket.proof ?? rawTicket.proofB64 ?? ""
        let tokenClass = try rawTicket.tokenClass.map(TokenClass.init(parsing:)) ?? fallbackTokenClass

        return ZkTicket(
            commitmentRoot: commitmentRoot,
            nullifier: nullifier,
            tokenClass: tokenClass,
            proof: proof
        )
    }
}

private func randomBytes(count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
}
