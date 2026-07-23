import Foundation

enum StreamingTextDecoder {
    nonisolated static func read(url: URL, detected: DetectedTextEncoding, start: Int, count: Int) throws -> RawTextReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(detected.bomLength))
        let encoding = TextEncodingDetector.stringEncoding(detected.encoding)
        let alignment = byteAlignment(detected.encoding)
        var carry = Data()
        var scalarOffset = 0
        var collected = String.UnicodeScalarView()
        var reachedEOF = false

        while collected.count <= count {
            if Task.isCancelled { throw RawTextReadError.cancelled }
            let block = try handle.read(upToCount: 256 * 1024) ?? Data()
            if block.isEmpty { reachedEOF = true }
            var input = carry
            input.append(block)
            let split = reachedEOF ? input.count : decodablePrefixLength(input, encoding: detected.encoding, alignment: alignment)
            let prefix = input.prefix(split)
            carry = Data(input.dropFirst(split))
            if !prefix.isEmpty {
                guard let text = String(data: prefix, encoding: encoding),
                      text.data(using: encoding, allowLossyConversion: false) == prefix else {
                    throw RawTextReadError.decodingFailed
                }
                for scalar in text.unicodeScalars {
                    if scalarOffset >= start, collected.count < count { collected.append(scalar) }
                    scalarOffset += 1
                }
            }
            if reachedEOF { break }
            if collected.count >= count { break }
        }

        if reachedEOF, !carry.isEmpty { throw RawTextReadError.decodingFailed }
        if reachedEOF, start > scalarOffset { throw RawTextReadError.rangePastEnd }
        let actualStart = min(start, scalarOffset)
        let scalarCount = collected.count
        let eofForRange = reachedEOF && actualStart + scalarCount >= scalarOffset
        return RawTextReadResult(
            text: String(collected), encoding: detected.encoding,
            requestedStart: start, actualStart: actualStart, scalarCount: scalarCount,
            nextStart: eofForRange ? nil : actualStart + scalarCount,
            reachedEOF: eofForRange, totalScalars: reachedEOF ? scalarOffset : nil
        )
    }

    nonisolated private static func byteAlignment(_ encoding: RawTextEncoding) -> Int {
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian: 2
        case .utf32LittleEndian, .utf32BigEndian: 4
        default: 1
        }
    }

    nonisolated private static func decodablePrefixLength(_ data: Data, encoding: RawTextEncoding, alignment: Int) -> Int {
        var length = data.count - (data.count % alignment)
        if encoding == .utf8 {
            let bytes = [UInt8](data)
            var trailing = 0
            while trailing < min(3, bytes.count), bytes[bytes.count - 1 - trailing] & 0xC0 == 0x80 { trailing += 1 }
            if trailing > 0 {
                let leadIndex = bytes.count - trailing - 1
                if leadIndex >= 0 {
                    let lead = bytes[leadIndex]
                    let expected = lead & 0xF8 == 0xF0 ? 3 : (lead & 0xF0 == 0xE0 ? 2 : (lead & 0xE0 == 0xC0 ? 1 : 0))
                    if trailing < expected { length = leadIndex }
                }
            } else if let last = bytes.last, last >= 0xC0 { length -= 1 }
        } else if [.gb18030, .big5, .shiftJIS, .eucKR].contains(encoding) {
            let stringEncoding = TextEncodingDetector.stringEncoding(encoding)
            for trailing in 0...min(4, data.count) {
                let candidateLength = data.count - trailing
                let candidate = data.prefix(candidateLength)
                if let text = String(data: candidate, encoding: stringEncoding),
                   text.data(using: stringEncoding, allowLossyConversion: false) == candidate {
                    return candidateLength
                }
            }
            length = max(0, data.count - 4)
        }
        return length
    }
}
