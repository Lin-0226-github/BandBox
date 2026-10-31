//
//  MiWearCommand.swift
//  BandBox
//
//  vela-v5 的 Command 消息构造与解析。字段号来自真机逆向（与 AstroBox / 小米运动健康同源）。
//
//  message Command {
//    uint32 type    = 1;     // 1=Account  2=System  20=Rpk  22=DataUpload  101=通用
//    uint32 subtype = 2;
//    Auth   auth    = 3;
//    bytes  rpkMessage  = 22;
//    bytes  dataUpload  = 24;
//    uint32 status  = 100;
//  }
//  message Auth {
//    PhoneNonce { bytes nonce = 1; }             phoneNonce = 30;
//    WatchNonce { bytes nonce = 1; bytes hmac = 2; }  watchNonce = 31;
//    AuthStep3  { bytes encryptedNonces = 1; bytes encryptedDeviceInfo = 2; } authStep3 = 32;
//  }
//

import Foundation

enum MiWearCommand {

    // MARK: - 命令类型

    enum CmdType: UInt64 {
        case account = 1
        case system = 2
        case rpk = 20
        case dataUpload = 22
        case generic = 101
    }

    // MARK: - 认证

    /// Step1：Command{type=1, subtype=26, auth{phoneNonce{nonce}}}
    static func authStep1(phoneNonce: Data) -> Data {
        let phoneNonceMsg = PB.bytes(1, phoneNonce)     // PhoneNonce.nonce = 1
        let auth = PB.bytes(30, phoneNonceMsg)          // Auth.phoneNonce = 30
        var cmd = Data()
        cmd += PB.uint(1, CmdType.account.rawValue)
        cmd += PB.uint(2, 26)
        cmd += PB.bytes(3, auth)
        return cmd
    }

    /// AuthDeviceInfo：field2 必须是 fixed32(float)，写成 varint 手环会拒绝
    static func authDeviceInfo(model: String, capability: UInt64, region: String, screenScale: Float = 36.0) -> Data {
        var info = Data()
        info += PB.uint(1, 0)                            // 必须显式序列化为 0
        info += PB.fixed32(2, screenScale)               // ★ float，不是 varint
        info += PB.string(3, model)
        info += PB.uint(4, capability)
        info += PB.string(5, region)
        return info
    }

    /// Step3：Command{type=1, subtype=27, auth{authStep3{encryptedSigns, encryptedDeviceInfo}}}
    static func authStep3(encryptedSigns: Data, encryptedDeviceInfo: Data) -> Data {
        var step3 = Data()
        step3 += PB.bytes(1, encryptedSigns)
        step3 += PB.bytes(2, encryptedDeviceInfo)
        let auth = PB.bytes(32, step3)
        var cmd = Data()
        cmd += PB.uint(1, CmdType.account.rawValue)
        cmd += PB.uint(2, 27)
        cmd += PB.bytes(3, auth)
        return cmd
    }

    // MARK: - 通用命令

    /// Command{type, subtype}
    static func plain(type: UInt64, subtype: UInt64) -> Data {
        PB.uint(1, type) + PB.uint(2, subtype)
    }

    /// Command{type, subtype, field=payload}
    static func command(type: UInt64, subtype: UInt64, field: Int, payload: Data) -> Data {
        PB.uint(1, type) + PB.uint(2, subtype) + PB.bytes(field, payload)
    }

    static func listApps() -> Data { plain(type: 20, subtype: 0) }
    static func battery() -> Data { plain(type: CmdType.system.rawValue, subtype: 1) }
    static func deviceInfo() -> Data { plain(type: CmdType.system.rawValue, subtype: 2) }

    /// 安装请求：type=20, subtype=1, rpkMessage{rpkInfo{id, unknown2=3, size}}
    static func installApp(package: String, size: Int) -> Data {
        var rpkInfo = Data()
        rpkInfo += PB.string(1, package)
        rpkInfo += PB.uint(2, 3)                 // ★ 恒为 3
        rpkInfo += PB.uint(3, UInt64(size))      // ★ 文件字节数在 field3
        let rpkMessage = PB.bytes(2, rpkInfo)
        return command(type: 20, subtype: 1, field: 22, payload: rpkMessage)
    }

    /// 卸载：type=20, subtype=3, rpkMessage{rpkDel{id, sha}}
    static func uninstallApp(package: String, sha: Data) -> Data {
        var item = Data()
        item += PB.string(1, package)
        item += PB.bytes(2, sha)
        let rpkMessage = PB.bytes(5, item)
        return command(type: 20, subtype: 3, field: 22, payload: rpkMessage)
    }

    /// 上传请求：type=22, subtype=0, dataUpload{dataUploadRequest{type=64, md5sum, size}}
    static func dataUploadRequest(md5: Data, size: Int, uploadType: UInt64 = 64) -> Data {
        var req = Data()
        req += PB.uint(1, uploadType)
        req += PB.bytes(2, md5)
        req += PB.uint(3, UInt64(size))
        let dataUpload = PB.bytes(1, req)
        return command(type: 22, subtype: 0, field: 24, payload: dataUpload)
    }

    // MARK: - 响应解析

    struct WatchNonceResponse {
        let nonce: Data
        let hmac: Data
    }

    /// 解析 type=1/subtype=26 响应中的 WatchNonce
    static func parseWatchNonce(_ fields: PB.Fields) -> WatchNonceResponse? {
        guard let auth = fields.firstBytes(3) else { return nil }
        let authFields = PB.parse(auth)
        guard let watchNonce = authFields.firstBytes(31) else { return nil }
        let wn = PB.parse(watchNonce)
        guard let nonce = wn.firstBytes(1), let hmac = wn.firstBytes(2) else { return nil }
        return WatchNonceResponse(nonce: nonce, hmac: hmac)
    }

    struct InstalledApp: Identifiable, Hashable {
        var id: String { package }
        let package: String
        let sha: Data
        let name: String
    }

    /// 解析 type=20 的 rpkList
    static func parseAppList(_ fields: PB.Fields) -> [InstalledApp] {
        guard let rpkMessage = fields.firstBytes(22) else { return [] }
        let rm = PB.parse(rpkMessage)
        guard let list = rm.firstBytes(1) else { return [] }
        let lf = PB.parse(list)
        var apps: [InstalledApp] = []
        for item in lf.allBytes(1) {
            let f = PB.parse(item)
            guard let package = f.firstString(1) else { continue }
            let sha = f.firstBytes(2) ?? Data()
            let name = f.firstString(5) ?? package
            apps.append(InstalledApp(package: package, sha: sha, name: name))
        }
        return apps
    }

    /// 解析 rpkInstallStart：cmd == 0 表示手环批准安装
    static func parseInstallApproval(_ fields: PB.Fields) -> UInt64? {
        guard let rpkMessage = fields.firstBytes(22) else { return nil }
        let rm = PB.parse(rpkMessage)
        guard let start = rm.firstBytes(3) else { return nil }
        return PB.parse(start).firstVarint(1)
    }

    struct UploadAck {
        let md5: Data
        let resumePosition: UInt64
        let chunkSize: UInt64
    }

    /// 解析 type=22 的 dataUploadAck
    static func parseUploadAck(_ fields: PB.Fields) -> UploadAck? {
        guard let dataUpload = fields.firstBytes(24) else { return nil }
        let du = PB.parse(dataUpload)
        guard let ack = du.firstBytes(2) else { return nil }
        let af = PB.parse(ack)
        let md5 = af.firstBytes(1) ?? Data()
        return UploadAck(md5: md5,
                         resumePosition: af.firstVarint(4) ?? 0,
                         chunkSize: af.firstVarint(5) ?? 0)
    }

    // MARK: - 系统信息（字段号各机型略有差异，这里做保守的通用提取）

    struct SystemInfo {
        var batteryLevel: Int?
        var batteryState: Int?
        var serialNumber: String?
        var firmware: String?
        var model: String?
        var rawFields: [(Int, String)] = []

        var displayLines: [String] {
            var lines: [String] = []
            if let b = batteryLevel { lines.append("电量 \(b)%") }
            if let b = batteryState { lines.append("充电状态 \(b)") }
            if let s = serialNumber { lines.append("序列号 \(s)") }
            if let f = firmware { lines.append("固件 \(f)") }
            if let m = model { lines.append("型号 \(m)") }
            if lines.isEmpty {
                lines = rawFields.map { "field\($0.0) = \($0.1)" }
            }
            return lines
        }
    }

    /// 从任意 Command 响应中尽力提取可读信息（调试友好）
    static func parseSystemInfo(_ fields: PB.Fields) -> SystemInfo {
        var info = SystemInfo()
        let ordered = fields.keys.sorted()
        var strings: [String] = []
        var varints: [UInt64] = []

        for key in ordered {
            for value in fields[key] ?? [] {
                switch value {
                case .varint(let n):
                    varints.append(n)
                    info.rawFields.append((key, "\(n)"))
                case .bytes(let d):
                    if let s = String(data: d, encoding: .utf8), d.count <= 64,
                       d.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                        strings.append(s)
                        info.rawFields.append((key, s))
                    } else {
                        info.rawFields.append((key, "\(d.count)B:" + d.prefix(16).map { String(format: "%02x", $0) }.joined()))
                    }
                case .fixed32(let d):
                    info.rawFields.append((key, "f32:" + d.map { String(format: "%02x", $0) }.joined()))
                case .fixed64(let d):
                    info.rawFields.append((key, "f64:" + d.map { String(format: "%02x", $0) }.joined()))
                }
            }
        }

        // 电量：0~100 的 varint
        if let b = varints.first(where: { $0 <= 100 }), let type = fields.firstVarint(1), type == 2 {
            info.batteryLevel = Int(b)
        }
        // 固件版本形如 1.2.3 / 3.1.32
        if let fw = strings.first(where: { $0.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil }) {
            info.firmware = fw
        }
        // 序列号：纯十六进制且长度 >= 8
        if let sn = strings.first(where: { $0.count >= 8 && $0.allSatisfy({ $0.isHexDigit }) }) {
            info.serialNumber = sn
        }
        if let m = strings.first(where: { $0.count >= 3 && !$0.contains(".") && $0 != info.firmware && $0 != info.serialNumber }) {
            info.model = m
        }
        return info
    }
}
