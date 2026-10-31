//
//  CRC16.swift
//  BandBox
//
//  CRC-16/ARC（poly 0xA001，反射，init 0x0000），计算范围仅帧 body。
//  与小米 vela-v5 协议一致：A5 A5 [type][seq][len][crc16][body]
//

import Foundation

enum CRC16 {
    /// CRC-16/ARC，无反射输入、反射输出，多项式 0xA001
    static func arc(_ data: Data) -> UInt16 {
        return arc([UInt8](data))
    }

    static func arc(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x0000
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc
    }

    // 单元测试向量（由 Python 参考实现生成）：
    //   arc([])                     = 0x0000
    //   arc([01,02,01,00])          = 0xACA1（帧内小端存储为 ac a1）
    //   完整帧 01020100 的 CRC 字段   = ac a1
}

// MARK: - CRC32（IEEE 802.3，与 zlib.crc32 一致）

enum CRC32 {
    static func compute(_ data: Data) -> UInt32 {
        return compute([UInt8](data))
    }

    static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            let idx = Int((crc ^ UInt32(b)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()
}
