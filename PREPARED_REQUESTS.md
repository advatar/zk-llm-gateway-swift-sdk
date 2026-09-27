# Prepared requests for Kline integration

Status: draft KCF-SDK-S first slice. No production, payment-finality, TEE or healthcare qualification.

## Flow

1. Finalize local minimization/redaction and construct `ChatCompletionsRequest`.
2. `PreparedInference.prepare` freezes the request ID and canonical authorization projection.
3. An injected `PreparedAuthorizationProviding` implementation computes the canonical gateway/Actum 48-byte SHAKE256 commitment and returns evidence bound to it.
4. `PreparedAuthorization` checks the ticket commitment and token class.
5. `PreparedGatewayClient` sends the unchanged prepared request through an injected `PreparedGatewayTransport`.

The SDK deliberately does **not** implement its own SHAKE256. Apple CryptoKit exposes SHA-3 digests but not the gateway's SHAKE256 XOF API used by the existing ActiveChain contract. Kline's first integration must therefore inject a reviewed local commitment/authorization implementation (for example the qualified Rust/sidecar path) rather than silently substituting SHA-384 or adding a second cryptographic interpretation.

`PreparedGatewayTransport` is the seam Kline uses to preserve its `SurfaceIOBoundary`; a caller that requires governed networking must not use an unreviewed internal `URLSession`. `URLSessionPreparedGatewayTransport` is supplied only as an explicit adapter for ordinary SDK consumers.

## Qualified subset

- text chat messages;
- `stream != true`;
- temperature omitted or one of 0, 0.5, 1, 1.5, 2;
- provider-option numbers restricted to portable integers;
- no embedded API credentials or alternate output-budget fields;
- `n`, when supplied, must equal 1;
- `store`, when supplied, must be false;
- HTTPS `/v1/infer` or `/relay`; numeric loopback HTTP is allowed for local tests.

Prepared projection bytes are deterministic sorted JSON but are **not themselves an authorization**. The injected provider remains responsible for computing the exact domain-separated SHAKE256 Digest384 commitment defined by gateway #11/#13 and for obtaining real payment evidence. A configured gateway public key is not TEE attestation.

## Remaining qualification

Run the Rust-owned shared vectors against this exact Swift implementation, including Unicode/null/numeric cases, and exercise an actual injected Kline transport. Test response binding/tamper and ambiguous dispatch against the native gateway. Do not merge or advertise confidential/clinical use before those gates pass.