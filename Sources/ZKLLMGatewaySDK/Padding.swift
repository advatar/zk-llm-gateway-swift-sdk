import Foundation

private let paddingMagic = Data("ZKLG".utf8)
private let paddingHeaderLength = 8
private let fillerBytes: [UInt8] = [0x20, 0x0A]

public func padPayload(_ payload: Data, targetLength: Int) throws -> Data {
    guard targetLength >= paddingHeaderLength else {
        throw ZKLLMGatewayError.invalidPadding("target length too small")
    }

    let maxPayload = targetLength - paddingHeaderLength
    guard payload.count <= maxPayload else {
        throw ZKLLMGatewayError.payloadTooLarge(actual: payload.count, limit: maxPayload)
    }

    var output = Data()
    output.append(paddingMagic)

    var length = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &length) { rawBuffer in
        output.append(contentsOf: rawBuffer)
    }

    output.append(payload)

    let remaining = targetLength - output.count
    if remaining > 0 {
        var filler = Data(count: remaining)
        for index in 0..<remaining {
            filler[index] = fillerBytes[index % fillerBytes.count]
        }
        output.append(filler)
    }

    return output
}

public func unpadPayload(_ padded: Data) throws -> Data {
    guard padded.count >= paddingHeaderLength else {
        throw ZKLLMGatewayError.invalidPadding("padded payload too small")
    }

    guard padded.prefix(4) == paddingMagic else {
        throw ZKLLMGatewayError.invalidPadding("bad magic")
    }

    let header = Array(padded[4..<8])
    let length = Int(
        UInt32(header[0]) |
        (UInt32(header[1]) << 8) |
        (UInt32(header[2]) << 16) |
        (UInt32(header[3]) << 24)
    )

    guard length <= padded.count - paddingHeaderLength else {
        throw ZKLLMGatewayError.invalidPadding("invalid length")
    }

    return padded.subdata(in: 8..<(8 + length))
}
