import Foundation
import ZKLLMGatewaySDK

@main
struct BasicChatExample {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let endpoint = URL(string: env["GATEWAY_URL"] ?? "https://api.gateway.example.com")!
        let pkB64 = try requireEnv("GATEWAY_PUBLIC_KEY_B64", from: env)

        let gatewayPublicKey = try GatewayPublicKey(base64: pkB64)
        let client = GatewayClient(
            endpoint: endpoint,
            gatewayPublicKey: gatewayPublicKey,
            tickets: DummyTicketSource()
        )

        let response = try await client.chatCompletions(
            tokenClass: .c2048,
            request: ChatCompletionsRequest(
                model: env["MODEL"] ?? "gpt-4o-mini",
                messages: [
                    .system("You are a helpful assistant."),
                    .user("Write a haiku about privacy-preserving payments."),
                ],
                temperature: 0.2
            )
        )

        print(response.firstText() ?? "")
    }

    private static func requireEnv(_ key: String, from env: [String: String]) throws -> String {
        guard let value = env[key], !value.isEmpty else {
            throw ExampleError.missingEnvironment(key)
        }
        return value
    }
}

private enum ExampleError: Error {
    case missingEnvironment(String)
}
