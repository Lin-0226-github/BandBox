//
//  MiWearPacket.swift
//  BandBox
//
//  vela-v5 帧格式（BLE 与 SPP 完全相同）：
//
//    [A5 A5] [type u8] [seq u8] [len u16 LE] [crc16 u16 LE] [body...]
//      magic   1=Ack    序号     body 长度     CRC16-ARC     payload
//              2=SessionConfig
//              3=Data
//
//  Data 帧 body = [channel u8] [opcode u8] [payload]
//    channel：1=Pb（命令） 2=Mass（文件数据） 7=NetWork ...
//    opcode ：1=Plain 明文  2=Encrypted（AES-128-CTR，IV = 会话密钥）
//
//  每收到一个 Data 帧都必须回 Ack（type=1，seq 相同），否则协议不推进。
//

import Foundation

enum PacketType: UInt8 {
    case ack = 1
    case sessionConfig = 2
    case data = 3
}

enum Channel: UInt8 {
    case pb = 1
    case mass = 2
    case massVoice = 3
    case fileSensor = 4
    case fileFitness = 5
    case ota = 6
    case network = 7
    case lyra = 8
    case fileResearch = 9
}

enum OpCode: UInt8 {
    case plain = 1
    case encrypted = 2
}

struct MiWearPacket {
    let type: UInt8
    let seq: UInt8
    let body: Data

    var isData: Bool { type == PacketType.data.rawValue }

    /// body = [channel][opcode][payload]
    var channel: UInt8? { body.count >= 1 ? body[body.startIndex] : nil }
    var opcode: UInt8? { body.count >= 2 ? body[body.startIndex + 1] : nil }
    var payload: Data { body.count >= 2 ? Data(body.dropFirst(2)) : Data() }

    // MARK: - 编码

    static func encode(type: UInt8, seq: UInt8, body: Data) -> Data {
        var f = Data()
        f.append(0xA5)
        f.append(0xA5)
        f.append(type & 0x0F)
        f.append(seq)
        let len = UInt16(body.count)
        f.append(UInt8(len & 0xFF))
        f.append(UInt8((len >> 8) & 0xFF))
        let crc = CRC16.arc(body)
        f.append(UInt8(crc & 0xFF))
        f.append(UInt8((crc >> 8) & 0xFF))
        f.append(body)
        return f
    }

    static func ack(seq: UInt8) -> Data {
        encode(type: PacketType.ack.rawValue, seq: seq, body: Data())
    }

    static func data(channel: Channel, opcode: OpCode, seq: UInt8, payload: Data) -> Data {
        var body = Data()
        body.append(channel.rawValue)
        body.append(opcode.rawValue)
        body.append(payload)
        return encode(type: PacketType.data.rawValue, seq: seq, body: body)
    }
}

/// 流式解帧器：BLE 的 notify 会把一帧切成多片送达，需要累积后按帧头 len 重组
final class PacketStreamParser {
    private var buffer = Data()

    func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    func reset() { buffer = Data() }

    /// 取出缓冲区中所有完整且 CRC 正确的帧
    func drain() -> [MiWearPacket] {
        var packets: [MiWearPacket] = []
        let b = [UInt8](buffer)
        var i = 0
        while i + 8 <= b.count {
            // 定位 magic
            if !(b[i] == 0xA5 && b[i + 1] == 0xA5) {
                i += 1
                continue
            }
            let type = b[i + 2] & 0x0F
            let seq = b[i + 3]
            let len = Int(b[i + 4]) | (Int(b[i + 5]) << 8)
            let crcGiven = UInt16(b[i + 6]) | (UInt16(b[i + 7]) << 8)
            if i + 8 + len > b.count { break }        // 数据未收全，等待下一片
            let body = Data(b[(i + 8)..<(i + 8 + len)])
            if CRC16.arc(body) == crcGiven {
                packets.append(MiWearPacket(type: type, seq: seq, body: body))
                i += 8 + len
            } else {
                i += 1                                // CRC 错误：跳过一个字节重新找 magic
            }
        }
        if i > 0 { buffer = Data(b[i...]) }
        return packets
    }
}
