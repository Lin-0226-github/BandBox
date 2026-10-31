//
//  Protobuf.swift
//  BandBox
//
//  极简 protobuf 编解码器（vela-v5 的 Command 消息字段不多，无需引入 SwiftProtobuf 依赖）。
//  支持 wire type：0 = varint，2 = length-delimited，5 = fixed32，1 = fixed64。
//

import Foundation

enum PB {

    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed32(Data)
        case fixed64(Data)
    }

    typealias Fields = [Int: [Value]]

    // MARK: - 编码

    static func varint(_ n: UInt64) -> Data {
        var data = Data()
        var v = n
        while true {
            let b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                data.append(b | 0x80)
            } else {
                data.append(b)
                break
            }
        }
        return data
    }

    static func tag(_ field: Int, _ wire: UInt8) -> Data {
        varint((UInt64(field) << 3) | UInt64(wire & 0x07))
    }

    static func uint(_ field: Int, _ value: UInt64) -> Data {
        tag(field, 0) + varint(value)
    }

    static func bytes(_ field: Int, _ data: Data) -> Data {
        tag(field, 2) + varint(UInt64(data.count)) + data
    }

    static func string(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    /// fixed32 —— 注意 vela-v5 的 AuthDeviceInfo.field2 是 float，必须用 fixed32 而非 varint
    static func fixed32(_ field: Int, _ value: Float) -> Data {
        var out = tag(field, 5)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        return out
    }

    // MARK: - 解码

    static func parse(_ data: Data) -> Fields {
        let b = [UInt8](data)
        var out: Fields = [:]
        var i = 0

        func readVarint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]
                i += 1
                if shift < 64 { v |= UInt64(byte & 0x7F) << shift }
                shift += 7
                if (byte & 0x80) == 0 { return v }
            }
            return nil
        }

        while i < b.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3)
            let wire = UInt8(key & 0x07)
            switch wire {
            case 0:
                guard let v = readVarint() else { return out }
                out[field, default: []].append(.varint(v))
            case 2:
                guard let len = readVarint() else { return out }
                let end = min(i + Int(len), b.count)
                out[field, default: []].append(.bytes(Data(b[i..<end])))
                i = end
            case 5:
                let end = min(i + 4, b.count)
                out[field, default: []].append(.fixed32(Data(b[i..<end])))
                i = end
            case 1:
                let end = min(i + 8, b.count)
                out[field, default: []].append(.fixed64(Data(b[i..<end])))
                i = end
            default:
                return out      // 未知 wire type，无法安全续读
            }
        }
        return out
    }
}

extension Dictionary where Key == Int, Value == [PB.Value] {

    func firstVarint(_ field: Int) -> UInt64? {
        guard let v = self[field]?.first, case .varint(let n) = v else { return nil }
        return n
    }

    func firstBytes(_ field: Int) -> Data? {
        guard let v = self[field]?.first, case .bytes(let d) = v else { return nil }
        return d
    }

    func firstString(_ field: Int) -> String? {
        guard let d = firstBytes(field) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func allBytes(_ field: Int) -> [Data] {
        (self[field] ?? []).compactMap { if case .bytes(let d) = $0 { return d } else { return nil } }
    }
}
