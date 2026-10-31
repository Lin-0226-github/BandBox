//
//  BLETransport.swift
//  BandBox
//
//  iOS 只暴露 BLE（GATT）给第三方 App，经典蓝牙 SPP/RFCOMM 需要 MFi 授权才能使用。
//  小米 Vela 设备的 vela-v5 帧在 BLE 与 SPP 上格式完全一致，因此这里用
//  fe95 服务的 RX/TX 特征承载同一套帧流。
//
//  已知的小米 Vela 通道（手环 9 / 手表 S3 之后）：
//    Service  0000FE95-0000-1000-8000-00805F9B34FB
//    RX(写)   0000005E-0000-1000-8000-00805F9B34FB
//    TX(通知) 0000005F-0000-1000-8000-00805F9B34FB
//  若设备上找不到上述特征，会自动降级为「扫描全部服务，选取 write+notify 特征对」。
//

import Foundation
import CoreBluetooth

// MARK: - 错误类型

enum BLEError: LocalizedError {
    case bluetoothUnavailable
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case notConnected
    case linkNotFound
    case writeTimeout
    case disconnected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:   return "本机不支持蓝牙低功耗"
        case .bluetoothPoweredOff:    return "蓝牙已关闭，请先在设置中打开"
        case .bluetoothUnauthorized:  return "没有蓝牙权限，请在设置中允许"
        case .notConnected:           return "尚未连接设备"
        case .linkNotFound:           return "未找到可用的读写特征"
        case .writeTimeout:           return "写入超时，设备可能已断开或不在可连接窗口"
        case .disconnected:           return "设备已断开连接"
        }
    }
}

// MARK: - 扫描到的设备

struct ScannedDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral

    static func == (lhs: ScannedDevice, rhs: ScannedDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var looksLikeXiaomi: Bool {
        let n = name.uppercased()
        return n.contains("MI BAND") || n.contains("XIAOMI") || n.contains("REDMI")
            || n.contains("MI WATCH") || n.contains("MIBAND") || n.contains("MB")
    }
}

struct BLELink {
    let writeCharacteristic: CBCharacteristic
    let notifyCharacteristic: CBCharacteristic
    let serviceUUID: CBUUID
}

// MARK: - BLE 传输

final class BLETransport: NSObject {

    static let miServiceUUID   = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")
    static let miRxUUID        = CBUUID(string: "0000005E-0000-1000-8000-00805F9B34FB")
    static let miTxUUID        = CBUUID(string: "0000005F-0000-1000-8000-00805F9B34FB")

    /// 收到设备端数据（已由底层拼帧前的原始字节流）
    var onData: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var link: BLELink?

    private var scanning = false
    private var discovered: [UUID: ScannedDevice] = [:]
    private var onScanUpdate: (([ScannedDevice]) -> Void)?

    private var powerContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<BLELink, Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?

    private var writeTimeoutTimer: DispatchSourceTimer?
    private let writeTimeout: TimeInterval = 6.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "bandbox.ble"))
    }

    // MARK: - 扫描

    func startScan(onUpdate: @escaping ([ScannedDevice]) -> Void) async throws {
        try await waitPowerOn()
        onScanUpdate = onUpdate
        discovered.removeAll()
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onLog?("开始扫描附近的蓝牙设备…")
    }

    func stopScan() {
        guard central.state == .poweredOn else { return }
        scanning = false
        central.stopScan()
        onLog?("停止扫描")
    }

    func currentDevices() -> [ScannedDevice] {
        discovered.values.sorted { ($0.rssi) > ($1.rssi) }
    }

    // MARK: - 连接

    func connect(to device: ScannedDevice) async throws {
        try await waitPowerOn()
        stopScan()
        peripheral = device.peripheral
        peripheral?.delegate = self

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectContinuation = cont
            central.connect(device.peripheral, options: nil)
        }
        onLog?("已连接 \(device.name)")

        let link = try await discoverLink()
        self.link = link
        try await enableNotify(on: link.notifyCharacteristic)
        onLog?("通道就绪：服务 \(link.serviceUUID.uuidString)，写特征 \(link.writeCharacteristic.uuid.uuidString)")
    }

    func disconnect() {
        guard let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
        peripheral = nil
        link = nil
    }

    var isConnected: Bool { peripheral?.state == .connected && link != nil }

    /// 单次可写入的最大字节数
    var mtu: Int {
        guard let p = peripheral, let c = link?.writeCharacteristic else { return 20 }
        let max = p.maximumWriteValueLength(for: .withResponse)
        return max > 0 ? max : 20
    }

    // MARK: - 写入

    /// 把整帧按 MTU 切片写入；手环依据帧头的 len 字段自行重组
    func write(_ data: Data) async throws {
        guard let p = peripheral, let ch = link?.writeCharacteristic else { throw BLEError.notConnected }
        let chunkSize = max(20, min(mtu, 512))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = Data(data[offset..<end])
            do {
                try await writeChunk(chunk, characteristic: ch, peripheral: p)
            } catch {
                throw error
            }
            offset = end
        }
    }

    private func writeChunk(_ chunk: Data, characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeContinuation = cont
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            startWriteTimeout()
        }
    }

    private func startWriteTimeout() {
        cancelWriteTimeout()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "bandbox.write.timeout"))
        timer.schedule(deadline: .now() + writeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if let cont = self.writeContinuation {
                self.writeContinuation = nil
                cont.resume(throwing: BLEError.writeTimeout)
            }
        }
        timer.resume()
        writeTimeoutTimer = timer
    }

    private func cancelWriteTimeout() {
        writeTimeoutTimer?.cancel()
        writeTimeoutTimer = nil
    }

    // MARK: - 内部：等待蓝牙就绪 / 发现服务

    private func waitPowerOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .unsupported:
            throw BLEError.bluetoothUnavailable
        case .unauthorized:
            throw BLEError.bluetoothUnauthorized
        case .poweredOff:
            throw BLEError.bluetoothPoweredOff
        default:
            break
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            powerContinuation = cont
        }
    }

    private func discoverLink() async throws -> BLELink {
        guard let p = peripheral else { throw BLEError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BLELink, Error>) in
            discoverContinuation = cont
            // 优先只发现小米服务，失败再全量发现
            p.discoverServices([BLETransport.miServiceUUID])
        }
    }

    private func enableNotify(on characteristic: CBCharacteristic) async throws {
        guard let p = peripheral else { throw BLEError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            notifyContinuation = cont
            p.setNotifyValue(true, for: characteristic)
        }
    }

    /// 在所有服务里挑选一对「可写 + 可通知」特征
    private func fallbackLink(from services: [CBService]) -> BLELink? {
        for service in services {
            let write = service.characteristics?.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            let notify = service.characteristics?.first {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            }
            if let w = write, let n = notify {
                return BLELink(writeCharacteristic: w, notifyCharacteristic: n, serviceUUID: service.uuid)
            }
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            powerContinuation?.resume()
            powerContinuation = nil
        case .poweredOff:
            powerContinuation?.resume(throwing: BLEError.bluetoothPoweredOff)
            powerContinuation = nil
        case .unauthorized:
            powerContinuation?.resume(throwing: BLEError.bluetoothUnauthorized)
            powerContinuation = nil
        case .unsupported:
            powerContinuation?.resume(throwing: BLEError.bluetoothUnavailable)
            powerContinuation = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if peripheral.name == nil && advertisementData[CBAdvertisementDataLocalNameKey] == nil { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "未知设备"
        let device = ScannedDevice(id: peripheral.identifier,
                                   name: name,
                                   rssi: RSSI.intValue,
                                   peripheral: peripheral)
        discovered[peripheral.identifier] = device
        let list = currentDevices()
        DispatchQueue.main.async { self.onScanUpdate?(list) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? BLEError.disconnected)
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.link = nil
        if let cont = writeContinuation {
            writeContinuation = nil
            cancelWriteTimeout()
            cont.resume(throwing: BLEError.disconnected)
        }
        onLog?("设备断开：\(error?.localizedDescription ?? "主动断开")")
        DispatchQueue.main.async { self.onDisconnect?() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            discoverContinuation?.resume(throwing: error)
            discoverContinuation = nil
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            // fe95 没有命中，改为全量发现
            peripheral.discoverServices(nil)
            return
        }
        // 若是全量发现（服务数 > 1 或首个不是 fe95），直接走降级挑选
        if let mi = services.first(where: { $0.uuid == BLETransport.miServiceUUID }) {
            peripheral.discoverCharacteristics(nil, for: mi)
            return
        }
        if services.count > 1 || services.first?.uuid != BLETransport.miServiceUUID {
            discoverAllCharacteristics(services, peripheral: peripheral)
        }
    }

    private func discoverAllCharacteristics(_ services: [CBService], peripheral: CBPeripheral) {
        var pending = services
        for service in services {
            if service.characteristics != nil { pending.removeAll { $0.uuid == service.uuid } }
        }
        for service in services where service.characteristics == nil {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if pending.isEmpty { finishDiscovery(peripheral: peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            discoverContinuation?.resume(throwing: error)
            discoverContinuation = nil
            return
        }

        // 优先使用小米已知特征
        if service.uuid == BLETransport.miServiceUUID {
            let chars = service.characteristics ?? []
            let rx = chars.first { $0.uuid == BLETransport.miRxUUID }
                ?? chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            let tx = chars.first { $0.uuid == BLETransport.miTxUUID }
                ?? chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            if let rx = rx, let tx = tx {
                discoverContinuation?.resume(returning: BLELink(writeCharacteristic: rx,
                                                                notifyCharacteristic: tx,
                                                                serviceUUID: service.uuid))
                discoverContinuation = nil
                return
            }
        }
        finishDiscovery(peripheral: peripheral)
    }

    private func finishDiscovery(peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        let allDiscovered = services.allSatisfy { $0.characteristics != nil }
        guard allDiscovered else { return }
        if let link = fallbackLink(from: services) {
            discoverContinuation?.resume(returning: link)
        } else {
            discoverContinuation?.resume(throwing: BLEError.linkNotFound)
        }
        discoverContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            onLog?("接收错误：\(error.localizedDescription)")
            return
        }
        if let data = characteristic.value, !data.isEmpty {
            DispatchQueue.main.async { self.onData?(data) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        cancelWriteTimeout()
        guard let cont = writeContinuation else { return }
        writeContinuation = nil
        if let error = error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let cont = notifyContinuation else { return }
        notifyContinuation = nil
        if let error = error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}
