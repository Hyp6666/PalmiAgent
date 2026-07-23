import Foundation
import CoreFoundation

struct DetectedTextEncoding: Sendable {
    let encoding: RawTextEncoding
    let bomLength: Int
}

enum TextEncodingDetector {
    private static let binaryMagics: [[UInt8]] = [
        Array("%PDF-".utf8), [0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06],
        [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1],
        [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
        [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF], Array("GIF8".utf8),
        [0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A], Array("BM".utf8),
        Array("SQLite format 3\0".utf8), [0x7F, 0x45, 0x4C, 0x46], [0x1F, 0x8B],
        Array("BZh".utf8), [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
    ]

    static func detect(sample: Data) throws -> DetectedTextEncoding {
        let bytes = [UInt8](sample)
        if binaryMagics.contains(where: { bytes.starts(with: $0) }) { throw RawTextReadError.binaryFile }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .init(encoding: .utf8, bomLength: 3) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .init(encoding: .utf32LittleEndian, bomLength: 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .init(encoding: .utf32BigEndian, bomLength: 4) }
        if bytes.starts(with: [0xFF, 0xFE]) { return .init(encoding: .utf16LittleEndian, bomLength: 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return .init(encoding: .utf16BigEndian, bomLength: 2) }
        if strictString(sample, encoding: .utf8) != nil { return .init(encoding: .utf8, bomLength: 0) }

        if let utf32 = detectUTF32(bytes) { return .init(encoding: utf32, bomLength: 0) }
        if let utf16 = detectUTF16(bytes) { return .init(encoding: utf16, bomLength: 0) }
        guard !bytes.contains(0), textLike(bytes) else { throw RawTextReadError.binaryFile }
        let candidates: [(RawTextEncoding, String.Encoding)] = [
            (.windows1252, .windowsCP1252),
            (.gb18030, cfEncoding(0x0632)),
            (.big5, cfEncoding(0x0A03)),
            (.shiftJIS, .shiftJIS),
            (.eucKR, cfEncoding(0x0940)),
            (.isoLatin1, .isoLatin1)
        ]
        for (raw, encoding) in candidates where strictString(sample, encoding: encoding) != nil {
            return .init(encoding: raw, bomLength: 0)
        }
        throw RawTextReadError.unsupportedEncoding
    }

    nonisolated static func stringEncoding(_ encoding: RawTextEncoding) -> String.Encoding {
        switch encoding {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .utf32LittleEndian: .utf32LittleEndian
        case .utf32BigEndian: .utf32BigEndian
        case .windows1252: .windowsCP1252
        case .isoLatin1: .isoLatin1
        case .gb18030: cfEncoding(0x0632)
        case .big5: cfEncoding(0x0A03)
        case .shiftJIS: .shiftJIS
        case .eucKR: cfEncoding(0x0940)
        }
    }

    nonisolated private static func cfEncoding(_ value: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
    }

    private static func strictString(_ data: Data, encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding),
              text.data(using: encoding, allowLossyConversion: false) == data else { return nil }
        return text
    }

    private static func detectUTF16(_ bytes: [UInt8]) -> RawTextEncoding? {
        guard bytes.count >= 4 else { return nil }
        let pairs = bytes.count / 2
        let evenNUL = stride(from: 0, to: pairs * 2, by: 2).filter { bytes[$0] == 0 }.count
        let oddNUL = stride(from: 1, to: pairs * 2, by: 2).filter { bytes[$0] == 0 }.count
        if Double(oddNUL) / Double(pairs) > 0.25 { return .utf16LittleEndian }
        if Double(evenNUL) / Double(pairs) > 0.25 { return .utf16BigEndian }
        return nil
    }

    private static func detectUTF32(_ bytes: [UInt8]) -> RawTextEncoding? {
        guard bytes.count >= 8 else { return nil }
        let groups = bytes.count / 4
        let le = stride(from: 0, to: groups * 4, by: 4).filter { bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 && bytes[$0 + 3] == 0 }.count
        let be = stride(from: 0, to: groups * 4, by: 4).filter { bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 }.count
        if Double(le) / Double(groups) > 0.5 { return .utf32LittleEndian }
        if Double(be) / Double(groups) > 0.5 { return .utf32BigEndian }
        return nil
    }

    private static func textLike(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        let accepted = bytes.filter { byte in
            byte >= 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }.count
        return Double(accepted) / Double(bytes.count) >= 0.85
    }
}
