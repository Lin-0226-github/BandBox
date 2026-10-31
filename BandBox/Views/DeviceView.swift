//
//  DeviceView.swift
//  BandBox
//
//  扫描 → 连接认证 → 设备信息 / 已装应用 / 安装资源
//

import SwiftUI
import UniformTypeIdentifiers

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false
    @State private var importKind: ResourceKind = .quickApp
    @State private var showLogs = false

    var body: some View {
        NavigationView {
            content
                .navigationTitle("设备")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showLogs = true
                        } label: {
                            Image(systemName: "text.alignleft")
                        }
                    }
                }
                .sheet(isPresented: $showLogs) {
                    LogView(logs: model.session.logs)
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                    switch result {
                    case .success(let url):
                        model.install(fileURL: url, kind: importKind)
                    case .failure(let error):
                        model.alertMessage = error.localizedDescription
                    }
                }
                .alert("提示", isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } })
                ) {
                    Button("好", role: .cancel) { model.alertMessage = nil }
                } message: {
                    Text(model.alertMessage ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            statusSection
            if model.isConnected {
                infoSection
                installSection
                appsSection
            } else {
                scanSection
            }
            noticeSection
        }
        .listStyle(.insetGrouped)
        .refreshable {
            if model.isConnected {
                model.refreshInfo()
                model.refreshApps()
            } else {
                model.startScan()
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(phaseColor.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: model.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundColor(phaseColor)
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if model.isWorking {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)

            if model.installProgress > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("安装进度")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(model.installProgress * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: model.installProgress)
                }
            }

            if model.isConnected {
                Button(role: .destructive) { model.disconnect() } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var phaseColor: Color {
        if case .failed = model.session.phase { return .red }
        return model.isConnected ? .green : .orange
    }

    private var statusTitle: String {
        switch model.session.phase {
        case .idle:            return "未连接"
        case .connecting:      return "正在连接…"
        case .authenticating:  return "正在认证…"
        case .ready:           return model.connectedDevice?.name ?? "已连接"
        case .busy(let job):   return job
        case .failed(let msg): return "连接失败：\(msg)"
        }
    }

    private var statusSubtitle: String {
        if let b = model.session.batteryLevel, model.isConnected {
            return "电量 \(b)%　·　vela-v5 会话已建立"
        }
        if model.isConnected { return "vela-v5 会话已建立" }
        if case .failed(let msg) = model.session.phase { return msg }
        return "请让手环处于可连接状态后扫描"
    }

    // MARK: - 扫描

    private var scanSection: some View {
        Section {
            Button {
                model.isScanning ? model.stopScan() : model.startScan()
            } label: {
                HStack {
                    Label(model.isScanning ? "停止扫描" : "开始扫描",
                          systemImage: model.isScanning ? "stop.circle" : "magnifyingglass")
                    Spacer()
                    if model.isScanning { ProgressView() }
                }
            }

            ForEach(model.devices) { device in
                Button { model.connect(device) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.hexagongrid")
                            .foregroundColor(device.looksLikeXiaomi ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .foregroundColor(.primary)
                            Text("RSSI \(device.rssi) dBm")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if model.devices.isEmpty && !model.isScanning {
                Text("还没有发现设备。若扫不到手环，请到「小米运动健康 → 设备 → 连接新手机」让手环进入可配对窗口，或关闭其他已连接手环的 App。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("附近的设备")
        }
    }

    // MARK: - 设备信息

    private var infoSection: some View {
        Section {
            ForEach(model.session.deviceInfoLines, id: \.self) { line in
                HStack {
                    Text(line)
                    Spacer()
                }
            }
            Button { model.refreshInfo() } label: {
                Label("刷新设备信息", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("设备信息")
        } footer: {
            Text("不同机型返回的字段编号存在差异，未能自动识别时会在下方日志中打印原始字段。")
        }
    }

    // MARK: - 安装

    private var installSection: some View {
        Section {
            ForEach(ResourceKind.allCases) { kind in
                Button {
                    importKind = kind
                    showImporter = true
                } label: {
                    HStack {
                        Image(systemName: icon(for: kind))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安装\(kind.rawValue)")
                                .foregroundColor(.primary)
                            Text(extensionHint(for: kind))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("安装资源")
        } footer: {
            Text(importKind.caution ?? "资源请从可信来源获取，安装前确认与机型匹配。")
        }
    }

    private func icon(for kind: ResourceKind) -> String {
        switch kind {
        case .quickApp:  return "app.badge.checkmark"
        case .watchFace: return "clock"
        case .firmware:  return "memorychip"
        }
    }

    private func extensionHint(for kind: ResourceKind) -> String {
        switch kind {
        case .quickApp:  return ".rpk（包名自动从 manifest.json 读取）"
        case .watchFace: return ".bin 表盘文件"
        case .firmware:  return "固件包（高风险，请谨慎）"
        }
    }

    // MARK: - 已安装应用

    private var appsSection: some View {
        Section {
            if model.session.apps.isEmpty {
                Text("暂无已安装应用（或手环未返回列表）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.session.apps) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.package)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.uninstall(app) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            Button { model.refreshApps() } label: {
                Label("刷新应用列表", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("已安装应用")
        }
    }

    private var noticeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("iOS 上的限制", systemImage: "info.circle")
                    .font(.subheadline.bold())
                Text("iOS 只向第三方 App 开放 BLE，经典蓝牙 SPP 需要 MFi 授权，因此传输速度低于安卓/桌面端，且部分机型会在认证后关闭 BLE。若安装卡住，请尝试减小「分块大小」、增大「发送间隔」，或在手环上进入「连接新手机」模式后重连。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
