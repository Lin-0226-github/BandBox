//
//  Data+Extensions.swift
//  BandBox
//

import Foundation

extension Data {
    /// 从十六进制字符串构造（忽略空格与 0x 前缀）
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let b = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self = Data(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
