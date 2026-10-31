//
//  SettingsStore.swift
//  BandBox
//
//  所有可调参数。协议在不同机型 / 固件上的表现差异较大，把关键参数暴露出来便于真机调试。
//

import Foundation
import Combine

final class SettingsStore: ObservableObject {

    // MARK: 设备凭证

    /// 32 位十六进制的 AuthKey（拥有它即拥有手环蓝牙最高权限，请勿外传）
    @Published var authKeyHex: String {
        didSet { store.set(authKeyHex, forKey: Key.authKey) }
    }

    /// 认证时上报给手环的手机型号。手环会据此判断「是否安卓手机」来决定快应用是否展示，
    /// 这就是 AstroBox 所谓「安卓伪装模式」的原理。
    @Published var deviceModel: String {
        didSet { store.set(deviceModel, forKey: Key.deviceModel) }
    }

    @Published var region: String {
        didSet { store.set(region, forKey: Key.region) }
    }

    @Published var capability: Int {
        didSet { store.set(capability, forKey: Key.capability) }
    }

    // MARK: 传输参数

    /// BLE 单帧承载的数据块大小（默认 244；不稳定可调小到 128）
    @Published var fragmentSize: Int {
        didSet { store.set(fragmentSize, forKey: Key.fragmentSize) }
    }

    /// 相邻数据块之间的间隔（毫秒）。灌太快手环会静默丢块。
    @Published var throttleMs: Int {
        didSet { store.set(throttleMs, forKey: Key.throttleMs) }
    }

    /// 上传请求里的 type 字段（快应用/表盘实测为 64）
    @Published var uploadType: Int {
        didSet { store.set(uploadType, forKey: Key.uploadType) }
    }

    // MARK: 派生

    var authKeyData: Data {
        Data(hexString: authKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
    }

    var authKeyIsValid: Bool { authKeyData.count == 16 }

    var capabilityValue: UInt64 { UInt64(max(0, capability)) }

    private let store = UserDefaults.standard

    private enum Key {
        static let authKey = "bb.authKey"
        static let deviceModel = "bb.deviceModel"
        static let region = "bb.region"
        static let capability = "bb.capability"
        static let fragmentSize = "bb.fragmentSize"
        static let throttleMs = "bb.throttleMs"
        static let uploadType = "bb.uploadType"
    }

    init() {
        authKeyHex = store.string(forKey: Key.authKey) ?? ""
        deviceModel = store.string(forKey: Key.deviceModel) ?? "iPhone"
        region = store.string(forKey: Key.region) ?? "CN"
        capability = store.object(forKey: Key.capability) as? Int ?? 25_171_686
        fragmentSize = store.object(forKey: Key.fragmentSize) as? Int ?? 244
        throttleMs = store.object(forKey: Key.throttleMs) as? Int ?? 70
        uploadType = store.object(forKey: Key.uploadType) as? Int ?? 64
    }

    // MARK: 预设

    static let modelPresets: [(name: String, model: String, capability: Int)] = [
        ("iPhone（默认）", "iPhone", 25_171_686),
        ("一加 PLZ110（安卓伪装）", "PLZ110", 25_171_686),
        ("小米 23046RP50C（安卓伪装）", "23046RP50C", 25_171_686),
        ("红米 22041216UC（安卓伪装）", "22041216UC", 25_171_686)
    ]

    func applyModelPreset(_ model: String, capability: Int) {
        deviceModel = model
        self.capability = capability
    }

    func resetTransportDefaults() {
        fragmentSize = 244
        throttleMs = 70
        uploadType = 64
    }
}
