import Foundation
import ZKLLMGatewaySDK

@main
struct AppGatewayExample {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let prompt = env["PROMPT"] ?? "Explain how token classes reduce size leakage."
        let systemPrompt = env["SYSTEM_PROMPT"] ?? "You are a helpful assistant."

        let gateway = try AppGatewayConfig.fromEnvironment(env).build()
        let answer = try await gateway.askWithSystem(systemPrompt, userPrompt: prompt)

        print(answer)
    }
}
