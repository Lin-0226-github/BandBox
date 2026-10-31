//
//  MiWearSession.swift
//  BandBox
//
//  一次完整的 vela-v5 会话：会话配置 → 三步认证 → 加密命令 → Mass 通道传文件。
//
//  时序（与小米运动健康 / AstroBox 同源）：
//    1. SessionConfig          连接后第一帧（BLE 与 SPP 相同，切勿发 BA DC FE 的旧协议 hello）
//    2. Auth Step1  type=1/26  明文 Channel.Pb  → 手环回 WatchNonce
//    3. 密钥派生 + HMAC 校验
//    4. Auth Step3  type=1/27  明文帧承载 CCM 密文 → 手环回 DeviceConfirm
//    5. 之后所有命令：Channel.Pb + OpCode.Encrypted（AES-128-CTR，IV = 会话密钥本身）
//    6. 文件数据必须走 Channel.Mass（用 Pb 传文件会被手环静默丢弃）
//

import Foundation
import Combine
import CryptoKit

enum SessionError: LocalizedError {
    case notReady
    case timeout(String)
    case noWatchNonce
    case hmacMismatch
    case installRejected(UInt64)
    case uploadRejected
    case missingAuthKey

    var errorDescription: String? {
        switch self {
        case .notReady:                  return "会话尚未就绪，请先连接设备"
        case .timeout(let stage):        return "等待超时（\(stage)）——手环可能不在可连接窗口，请重连或重启手环后重试"
        case .noWatchNonce:              return "未收到 WatchNonce，认证失败"
        case .hmacMismatch:              return "HMAC 校验失败：AuthKey 不正确，或该设备使用的不是 vela-v5 协议"
        case .installRejected(let code): return "手环拒绝安装（cmd=\(code)）：通常是存储空间不足或资源包与机型不适配"
        case .uploadRejected:            return "手环未批准上传，安装会话可能已超时，请重试"
        case .missingAuthKey:            return "请先在设置中填入设备的 AuthKey"
        }
    }
}

enum ResourceKind: String, CaseIterable, Identifiable {
    case quickApp = "快应用"
    case watchFace = "表盘"
    case firmware = "固件"

    var id: String { rawValue }

    var fileExtensions: [String] {
        switch self {
        case .quickApp:  return ["rpk"]
        case .watchFace: return ["bin"]
        case .firmware:  return ["bin", "fw", "zip"]
        }
    }

    var caution: String? {
        switch self {
        case .firmware:  return "刷写固件存在变砖风险，请确认资源与机型完全匹配，且电量充足。"
        case .watchFace: return "表盘需与机型匹配，不适配的表盘可能导致渲染异常，可长按删除恢复。"
        case .quickApp:  return "第三方快应用未经过官方签名校验，请仅安装可信来源的资源。"
        }
    }
}

@MainActor
final class MiWearSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case authenticating
        case ready
        case busy(String)
        case failed(String)
    }

    // MARK: 对外状态

    @Published var phase: Phase = .idle
    @Published var logs: [String] = []
    @Published var batteryLevel: Int?
    @Published var deviceInfoLines: [String] = []
    @Published var apps: [MiWearCommand.InstalledApp] = []

    let transport = BLETransport()
    var settings: SettingsStore

    // MARK: 内部状态

    private var keys: MiWearCrypto.SessionKeys?
    private var phoneNonce = Data()
    private var seq: UInt8 = 2
    private let parser = PacketStreamParser()

    private var writeQueue: [Data] = []
    private var isWriting = false

    private var collected: [PB.Fields] = []
    private var waiter: Waiter?
    private var timeoutWork: DispatchWorkItem?

    private struct Waiter {
        let predicate: (PB.Fields) -> Bool
        let continuation: CheckedContinuation<[PB.Fields], Error>
    }

    /// SessionConfig 帧的 body（与 AstroBox / 小米运动健康一致）
    static let sessionConfigBodyHex = "0101030001000002020000fc03020020000402001027"

    init(settings: SettingsStore) {
        self.settings = settings
        transport.onData = { [weak self] data in
            DispatchQueue.main.async { self?.handleIncoming(data) }
        }
        transport.onLog = { [weak self] msg in
            DispatchQueue.main.async { self?.log(msg) }
        }
        transport.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.keys = nil
                self.writeQueue.removeAll()
                self.phase = .idle
                self.log("连接已断开")
            }
        }
    }

    // MARK: - 日志

    func log(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logs.append("[\(stamp)] \(message)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 连接与认证

    func connectAndAuth(to device: ScannedDevice) async throws {
        phase = .connecting
        log("正在连接 \(device.name) …")
        try await transport.connect(to: device)

        guard !settings.authKeyData.isEmpty else {
            phase = .failed("缺少 AuthKey")
            throw SessionError.missingAuthKey
        }

        phase = .authenticating
        let authKey = settings.authKeyData

        // 1) SessionConfig
        if let body = Data(hexString: Self.sessionConfigBodyHex) {
            send(MiWearPacket.encode(type: PacketType.sessionConfig.rawValue, seq: 0, body: body), priority: true)
            log("已发送 SessionConfig")
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 2) Auth Step1
        phoneNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let step1 = MiWearCommand.authStep1(phoneNonce: phoneNonce)
        send(MiWearPacket.data(channel: .pb, opcode: .plain, seq: 0, payload: step1), priority: true)
        log("已发送 Auth Step1，等待 WatchNonce …")

        let step1Responses = try await waitForResponse(timeout: 12, stage: "WatchNonce") { fields in
            fields.firstVarint(1) == 1 && MiWearCommand.parseWatchNonce(fields) != nil
        }
        guard let watchNonce = step1Responses.compactMap({ MiWearCommand.parseWatchNonce($0) }).first else {
            phase = .failed("认证失败")
            throw SessionError.noWatchNonce
        }

        // 3) 派生密钥并校验手环签名
        let k = MiWearCrypto.deriveKeys(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce.nonce)
        keys = k
        guard MiWearCrypto.verifyWatchHmac(decKey: k.decKey,
                                           watchNonce: watchNonce.nonce,
                                           phoneNonce: phoneNonce,
                                           received: watchNonce.hmac) else {
            phase = .failed("AuthKey 错误")
            log("HMAC 校验失败，请核对 AuthKey（32 位十六进制）")
            throw SessionError.hmacMismatch
        }
        log("密钥协商完成 encKey=\(Data(k.encKey.prefix(4)).hexString)…")

        // 4) Auth Step3
        let deviceInfoMsg = MiWearCommand.authDeviceInfo(model: settings.deviceModel,
                                                         capability: settings.capabilityValue,
                                                         region: settings.region)
        let signs = MiWearCrypto.encryptedSigns(encKey: k.encKey,
                                                phoneNonce: phoneNonce,
                                                watchNonce: watchNonce.nonce)
        var nonce12 = Data()
        nonce12.append(k.encNonce)
        nonce12.append(contentsOf: [0, 0, 0, 0])
        nonce12.append(contentsOf: [0, 0, 0, 0])
        let encInfo = MiWearCrypto.aesCCMEncrypt(key: k.encKey, nonce: nonce12, plaintext: deviceInfoMsg)
        let step3 = MiWearCommand.authStep3(encryptedSigns: signs, encryptedDeviceInfo: encInfo)
        send(MiWearPacket.data(channel: .pb, opcode: .plain, seq: 1, payload: step3), priority: true)

        _ = try await waitForResponse(timeout: 12, stage: "DeviceConfirm") { fields in
            fields.firstVarint(1) == 1 && fields.firstVarint(2) == 27
        }
        phase = .ready
        log("认证完成，会话就绪")

        Task { try? await self.refreshDeviceInfo() }
    }

    func disconnect() {
        keys = nil
        writeQueue.removeAll()
        transport.disconnect()
        phase = .idle
    }

    // MARK: - 命令

    @discardableResult
    func sendCommand(_ payload: Data,
                     timeout: TimeInterval = 6,
                     stage: String = "命令",
                     predicate: ((PB.Fields) -> Bool)? = nil) async throws -> [PB.Fields] {
        guard let k = keys else { throw SessionError.notReady }
        let cipher = MiWearCrypto.aesCTR(key: k.encKey, iv: k.encKey, data: payload)
        send(MiWearPacket.data(channel: .pb, opcode: .encrypted, seq: nextSeq(), payload: cipher))
        let requestedType = PB.parse(payload).firstVarint(1)
        let filter = predicate ?? { fields in fields.firstVarint(1) == requestedType }
        return try await waitForResponse(timeout: timeout, stage: stage, predicate: filter)
    }

    func refreshDeviceInfo() async throws {
        let responses = try await sendCommand(MiWearCommand.deviceInfo(), timeout: 6, stage: "设备信息")
        if let fields = responses.first {
            let info = MiWearCommand.parseSystemInfo(fields)
            deviceInfoLines = info.displayLines
            batteryLevel = info.batteryLevel ?? batteryLevel
        }
        let batteryResponses = try? await sendCommand(MiWearCommand.battery(), timeout: 5, stage: "电量")
        if let fields = batteryResponses?.first {
            let info = MiWearCommand.parseSystemInfo(fields)
            batteryLevel = info.batteryLevel ?? batteryLevel
        }
    }

    func refreshApps() async throws {
        let responses = try await sendCommand(MiWearCommand.listApps(), timeout: 6, stage: "应用列表")
        for fields in responses {
            let list = MiWearCommand.parseAppList(fields)
            if !list.isEmpty {
                apps = list
                log("已安装应用：\(list.count) 个")
                return
            }
        }
    }

    func uninstall(app: MiWearCommand.InstalledApp) async throws {
        try await sendCommand(MiWearCommand.uninstallApp(package: app.package, sha: app.sha),
                              timeout: 6,
                              stage: "卸载")
        log("已发送卸载命令：\(app.package)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try? await refreshApps()
    }

    // MARK: - 安装资源

    /// 走 type=20 → type=22 → Mass 通道安装一个资源包
    func install(data: Data, package: String, kind: ResourceKind,
                 progress: @escaping (Double) -> Void) async throws {
        guard keys != nil else { throw SessionError.notReady }
        phase = .busy("准备安装")
        log("开始安装 \(kind.rawValue)：\(package)，\(data.count) 字节")

        let md5 = Data(Insecure.MD5.hash(data: data))

        // 预热：先拉一次应用列表，激活手环侧 rpk 服务
        _ = try? await sendCommand(MiWearCommand.listApps(), timeout: 2.5, stage: "预热")

        // 1) 安装请求
        let installCmd = MiWearCommand.installApp(package: package, size: data.count)
        let encrypted = MiWearCrypto.aesCTR(key: keys!.encKey, iv: keys!.encKey, data: installCmd)
        send(MiWearPacket.data(channel: .pb, opcode: .encrypted, seq: nextSeq(), payload: encrypted))
        log("已发送安装请求，等待手环批准 …")

        // 2) 等待 rpkInstallStart（cmd == 0 表示批准）
        let approvalResponses = try await waitForResponse(timeout: 10, stage: "安装批准") { fields in
            fields.firstVarint(1) == 20 && MiWearCommand.parseInstallApproval(fields) != nil
        }
        guard let code = approvalResponses.compactMap({ MiWearCommand.parseInstallApproval($0) }).first else {
            throw SessionError.uploadRejected
        }
        guard code == 0 else { throw SessionError.installRejected(code) }
        log("手环已批准（cmd=0），立即发起上传请求")

        // 3) 上传请求（批准后必须毫秒级发出，否则会话超时）
        let uploadCmd = MiWearCommand.dataUploadRequest(md5: md5,
                                                        size: data.count,
                                                        uploadType: UInt64(settings.uploadType))
        let uploadEncrypted = MiWearCrypto.aesCTR(key: keys!.encKey, iv: keys!.encKey, data: uploadCmd)
        send(MiWearPacket.data(channel: .pb, opcode: .encrypted, seq: nextSeq(), payload: uploadEncrypted))

        let ackResponses = try await waitForResponse(timeout: 10, stage: "上传确认") { fields in
            fields.firstVarint(1) == 22 && MiWearCommand.parseUploadAck(fields) != nil
        }
        guard let ack = ackResponses.compactMap({ MiWearCommand.parseUploadAck($0) }).first else {
            throw SessionError.uploadRejected
        }
        log("收到 dataUploadAck：分片 \(ack.chunkSize) 字节，断点 \(ack.resumePosition)")

        // 4) Mass 通道分块上传
        var inner = Data()
        inner.append(0x00)
        inner.append(UInt8(max(0, min(255, settings.uploadType))))   // upload type，实测为 64
        inner.append(md5)
        var sizeLE = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &sizeLE) { inner.append(contentsOf: $0) }
        inner.append(data)
        var crc = CRC32.compute(inner).littleEndian
        withUnsafeBytes(of: &crc) { inner.append(contentsOf: $0) }

        let fragSize = max(64, settings.fragmentSize)
        let total = (inner.count + fragSize - 1) / fragSize
        log("开始上传：\(total) 块 × \(fragSize) 字节")

        for index in 0..<total {
            let start = index * fragSize
            let end = min(start + fragSize, inner.count)
            let frag = Data(inner[start..<end])

            var payload = Data()
            var totalU16 = UInt16(total).littleEndian
            var indexU16 = UInt16(index + 1).littleEndian
            withUnsafeBytes(of: &totalU16) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &indexU16) { payload.append(contentsOf: $0) }
            payload.append(frag)

            send(MiWearPacket.data(channel: .mass, opcode: .plain, seq: nextSeq(), payload: payload))

            if index % 20 == 0 || index == total - 1 {
                progress(Double(index + 1) / Double(total))
            }
            if index % 100 == 0 {
                log("上传进度 \(index + 1)/\(total)")
            }
            // 节流：灌太快手环会静默丢块
            try? await Task.sleep(nanoseconds: UInt64(settings.throttleMs * 1_000_000))
        }
        progress(1.0)
        log("上传完成，等待手环写入 …")

        // 5) 等待写入完成后复查
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        try? await refreshApps()
        phase = .ready
        log("安装流程结束，请在手环上确认（快应用可能在「更多」或表盘列表中）")
    }

    // MARK: - 发送队列（串行化，避免多帧交错）

    private func send(_ frame: Data, priority: Bool = false) {
        if priority {
            writeQueue.insert(frame, at: 0)
        } else {
            writeQueue.append(frame)
        }
        pump()
    }

    private func pump() {
        guard !isWriting, !writeQueue.isEmpty else { return }
        let frame = writeQueue.removeFirst()
        isWriting = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.transport.write(frame)
            } catch {
                self.log("写入失败：\(error.localizedDescription)")
            }
            self.isWriting = false
            self.pump()
        }
    }

    private func nextSeq() -> UInt8 {
        let current = seq
        seq = seq &+ 1
        return current
    }

    // MARK: - 接收

    private func handleIncoming(_ chunk: Data) {
        parser.append(chunk)
        let packets = parser.drain()
        for packet in packets {
            guard packet.isData, let opcode = packet.opcode else { continue }
            // 每个 Data 帧都必须回 Ack
            send(MiWearPacket.ack(seq: packet.seq), priority: true)

            var payload = packet.payload
            if opcode == OpCode.encrypted.rawValue, let k = keys {
                payload = MiWearCrypto.aesCTR(key: k.decKey, iv: k.decKey, data: payload)
            }
            let fields = PB.parse(payload)
            if let t = fields.firstVarint(1), let s = fields.firstVarint(2) {
                log("← type=\(t) subtype=\(s) (\(payload.count)B)")
            }
            collected.append(fields)
        }
        if !packets.isEmpty { checkWaiter() }
    }

    private func waitForResponse(timeout: TimeInterval,
                                 stage: String,
                                 predicate: @escaping (PB.Fields) -> Bool) async throws -> [PB.Fields] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[PB.Fields], Error>) in
            self.collected.removeAll()
            self.waiter = Waiter(predicate: predicate, continuation: cont)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.continuation.resume(throwing: SessionError.timeout(stage))
            }
            self.timeoutWork?.cancel()
            self.timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            checkWaiter()
        }
    }

    private func checkWaiter() {
        guard let waiter = waiter else { return }
        let matched = collected.filter { waiter.predicate($0) }
        guard !matched.isEmpty else { return }
        self.waiter = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        waiter.continuation.resume(returning: matched)
    }
}

// MARK: - CRC32

// CRC32 实现位于 Protocol/CRC16.swift（与 CRC-16/ARC 同文件）
