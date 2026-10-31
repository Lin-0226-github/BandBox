//
//  SettingsView.swift
//  BandBox
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var extractMessage: String?

    var body: some View {
        NavigationView {
            Form {
                credentialSection
                transportSection
                identitySection
                aboutSection
            }
            .navigationTitle("设置")
            .alert("提取结果", isPresented: Binding(
                get: { extractMessage != nil },
                set: { if !$0 { extractMessage = nil } })
            ) {
                Button("好", role: .cancel) { extractMessage = nil }
            } message: {
                Text(extractMessage ?? "")
            }
        }
    }

    // MARK: - 凭证

    private var credentialSection: some View {
        Section {
            HStack {
                TextField("32 位十六进制 AuthKey", text: $settings.authKeyHex)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if settings.authKeyIsValid {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else if !settings.authKeyHex.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
            }

            Button {
                extractFromPasteboard()
            } label: {
                Label("从剪贴板提取", systemImage: "doc.on.clipboard")
            }

            NavigationLink {
                AuthKeyGuideView()
            } label: {
                Label("如何获取 AuthKey", systemImage: "questionmark.circle")
            }

            Text(authKeyHint)
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("设备凭证")
        }
    }

    private func extractFromPasteboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            extractMessage = "剪贴板是空的。请先复制小米运动健康日志片段，或直接粘贴 32 位 AuthKey。"
            return
        }
        if AuthKeyExtractor.isValid(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            settings.authKeyHex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            extractMessage = "已识别为 AuthKey（32 位十六进制）。"
            return
        }
        if let key = AuthKeyExtractor.extract(from: text) {
            settings.authKeyHex = key
            extractMessage = "从剪贴板内容中提取到 AuthKey：\(key.prefix(4))…\(key.suffix(4))"
        } else {
            extractMessage = "没有找到 AuthKey。请确认复制的是包含 authKey 字段的日志内容。"
        }
    }

    private var authKeyHint: String {
        if settings.authKeyHex.isEmpty {
            return "还没填。AuthKey 存在「小米运动健康」里，用安卓端的日志读取工具取出；点上方「如何获取 AuthKey」看分步说明。"
        }
        if settings.authKeyIsValid { return "格式正确（16 字节），可以连接手环了。" }
        return "格式不正确：应为 32 个十六进制字符，当前解析出 \(settings.authKeyData.count) 字节。"
    }


    // MARK: - 传输参数

    private var transportSection: some View {
        Section {
            Stepper(value: $settings.fragmentSize, in: 64...1000, step: 4) {
                HStack {
                    Text("分块大小")
                    Spacer()
                    Text("\(settings.fragmentSize) B")
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: $settings.throttleMs, in: 0...500, step: 10) {
                HStack {
                    Text("发送间隔")
                    Spacer()
                    Text("\(settings.throttleMs) ms")
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: $settings.uploadType, in: 0...255, step: 1) {
                HStack {
                    Text("上传 type")
                    Spacer()
                    Text("\(settings.uploadType)")
                        .foregroundColor(.secondary)
                }
            }

            Button("恢复传输默认值") { settings.resetTransportDefaults() }

            Text("上传卡住或手环静默丢块时，把「分块大小」降到 128、「发送间隔」提到 150ms 再试。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("传输调优")
        }
    }

    // MARK: - 身份（安卓伪装）

    private var identitySection: some View {
        Section {
            Picker("上报机型", selection: $settings.deviceModel) {
                ForEach(SettingsStore.modelPresets, id: \.model) { preset in
                    Text(preset.name).tag(preset.model)
                }
            }

            HStack {
                Text("机型标识")
                Spacer()
                TextField("iPhone", text: $settings.deviceModel)
                    .multilineTextAlignment(.trailing)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            HStack {
                Text("地区")
                Spacer()
                TextField("CN", text: $settings.region)
                    .multilineTextAlignment(.trailing)
                    .autocapitalization(.none)
            }

            HStack {
                Text("capability")
                Spacer()
                TextField("25171686", value: $settings.capability, formatter: NumberFormatter())
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }

            Text("小米手环依据上报的机型判断手机系统：识别为 iOS 时会隐藏快应用入口。切换成安卓机型标识（安卓伪装）后重新连接，手环会重新显示快应用；但该模式下连接维持时间很短，安装资源时请切回 iPhone 标识。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("设备身份")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("协议"); Spacer(); Text("vela-v5").foregroundColor(.secondary) }
            HStack { Text("传输通道"); Spacer(); Text("BLE GATT").foregroundColor(.secondary) }
            HStack { Text("最低系统"); Spacer(); Text("iOS 15.0").foregroundColor(.secondary) }
        } header: {
            Text("关于")
        } footer: {
            Text("本工具为第三方社区项目，与小米官方无关。刷写固件、强装不适配资源存在损坏设备的风险，请自行承担。")
        }
    }
}
