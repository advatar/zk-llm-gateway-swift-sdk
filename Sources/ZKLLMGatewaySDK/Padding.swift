import Foundation

public func padPayload(_ payload: Data, targetLength: Int) throws -> Data {
    guard payload.count <= targetLength else {
        throw ZKLLMGatewayError.payloadTooLarge(actual: payload.count, limit: targetLength)
    }

    var output = Data(capacity: targetLength)
    output.append(payload)

    let remaining = targetLength - output.count
    if remaining > 0 {
        output.append(Data(repeating: 0, count: remaining))
    }

    return output
}

public func unpadPayload(_ padded: Data) throws -> Data {
    var end = padded.count
    while end > 0 && padded[end - 1] == 0 {
        end -= 1
    }

    return padded.prefix(end)
}
