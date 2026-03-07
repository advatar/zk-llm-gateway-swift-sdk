# ZK LLM Gateway SDK (Swift)

Pure Swift SDK for the **ZK LLM Gateway**: **end-to-end encrypted envelopes**, **token-class padding**, and **ZK-ready usage tickets** for metered LLM inference.

This package mirrors the existing Python, Rust, and TypeScript SDK behavior while using native Swift APIs (`Foundation` + `CryptoKit`) for Apple platforms.

> Privacy note:
> - This SDK protects prompts and responses from relays/intermediaries and reduces size fingerprinting with fixed-size padding.
> - It does **not** prevent the upstream LLM provider from correlating requests through prompt content, timing, or other side channels.

## Features

- X25519 + HKDF-SHA256 + ChaCha20-Poly1305 envelope encryption
- Token classes (`c256`, `c512`, `c1024`, `c2048`, `c4096`)
- Async `GatewayClient` for encrypted `/v1/infer`
- OpenAI-style chat request/response helpers
- Dummy and file-backed ticket sources
- Optional regex-based redaction helpers

## Requirements

- Swift 6+
- iOS 15+ or macOS 12+

## Install

```swift
dependencies: [
    .package(url: "https://github.com/your-org/zk-llm-gateway-swift-sdk.git", branch: "main")
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ZKLLMGatewaySDK", package: "zk-llm-gateway-swift-sdk")
    ]
)
```

## Quickstart

```swift
import Foundation
import ZKLLMGatewaySDK

let endpoint = URL(string: ProcessInfo.processInfo.environment["GATEWAY_URL"] ?? "https://api.gateway.example.com")!
let pkB64 = ProcessInfo.processInfo.environment["GATEWAY_PUBLIC_KEY_B64"]!

let gatewayPK = try GatewayPublicKey(base64: pkB64)
let tickets = DummyTicketSource()

let client = GatewayClient(
    endpoint: endpoint,
    gatewayPublicKey: gatewayPK,
    tickets: tickets
)

let response = try await client.chatCompletions(
    tokenClass: .c2048,
    request: ChatCompletionsRequest(
        model: ProcessInfo.processInfo.environment["MODEL"] ?? "gpt-4o-mini",
        messages: [
            .system("You are a helpful assistant."),
            .user("Write a haiku about privacy-preserving payments."),
        ],
        temperature: 0.2
    )
)

print(response.firstText() ?? "")
```

## Ticket Sources

Dummy tickets:

```swift
let tickets = DummyTicketSource()
```

JSON ticket file:

```swift
let tickets = try FileTicketSource(path: "./tickets.json")
```

Expected format:

```json
[
  {
    "commitment_root": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "nullifier": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
    "token_class": "c2048",
    "proof": ""
  }
]
```

## Redaction

```swift
let redactor = Redactor(mode: .stablePerValue)
let result = redactor.redactText("Email me at alice@example.com (sk-verysecret...)")
print(result.redacted)
let restored = redactor.rehydrateText(result.redacted, map: result.map)
```

## Development

```bash
swift test
swift build
```
