//
//  AppModel.swift
//  BandBox
//
//  连接 / 安装 / 日志的统一入口，串联 BLETransport 与 MiWearSession。
//

import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    let settings = SettingsStore()
    private(set) var session: MiWearSession!

    @Published var devices: [ScannedDevice] = []
    @Published var isScanning = false
    @Published var connectedDevice: ScannedDevice?
    @Published var isWorking = false
    @Published var installProgress: Double = 0
    @Published var alertMessage: String?
    @Published var lastError: String?

    init() {
        session = MiWearSession(settings: settings)
    }

    var isConnected: Bool { connectedDevice != nil && session.transport.isConnected }

    // MARK: - 扫描

    func startScan() {
        guard !isScanning else { return }
        devices.removeAll()
        isScanning = true
        Task {
            do {
                try await session.transport.startScan { [weak self] list in
                    Task { @MainActor in self?.devices = list }
                }
            } catch {
                isScanning = false
                lastError = error.localizedDescription
                alertMessage = error.localizedDescription
            }
        }
        // 30 秒后自动停止（本类型已隔离在主线程，直接调用即可）
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self.stopScan()
        }
    }

    func stopScan() {
        session.transport.stopScan()
        isScanning = false
    }

    // MARK: - 连接

    func connect(_ device: ScannedDevice) {
        isWorking = true
        Task {
            do {
                try await session.connectAndAuth(to: device)
                connectedDevice = device
                try? await session.refreshDeviceInfo()
                try? await session.refreshApps()
            } catch {
                lastError = error.localizedDescription
                alertMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func disconnect() {
        session.disconnect()
        connectedDevice = nil
    }

    // MARK: - 刷新

    func refreshInfo() {
        Task {
            isWorking = true
            do { try await session.refreshDeviceInfo() }
            catch { alertMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func refreshApps() {
        Task {
            isWorking = true
            do { try await session.refreshApps() }
            catch { alertMessage = error.localizedDescription }
            isWorking = false
        }
    }

    func uninstall(_ app: MiWearCommand.InstalledApp) {
        Task {
            isWorking = true
            do { try await session.uninstall(app: app) }
            catch { alertMessage = error.localizedDescription }
            isWorking = false
        }
    }

    // MARK: - 安装

    func install(fileURL: URL, kind: ResourceKind) {
        guard fileURL.startAccessingSecurityScopedResource() else {
            alertMessage = "无法读取所选文件（沙盒授权失败）"
            return
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: fileURL) else {
            alertMessage = "文件读取失败"
            return
        }
        let package = Self.packageName(from: fileURL, data: data, kind: kind)

        isWorking = true
        installProgress = 0
        Task {
            do {
                try await session.install(data: data, package: package, kind: kind) { [weak self] p in
                    Task { @MainActor in self?.installProgress = p }
                }
                alertMessage = "安装流程已完成，请在手环上查看"
            } catch {
                alertMessage = error.localizedDescription
                lastError = error.localizedDescription
            }
            isWorking = false
            installProgress = 0
        }
    }

    /// 从 rpk（zip 结构）里解析 manifest.json 的 package 字段；表盘/固件退化为文件名
    static func packageName(from url: URL, data: Data, kind: ResourceKind) -> String {
        if kind == .quickApp {
            if let name = Self.packageFromZip(data: data) { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// rpk 本质是 zip，manifest.json 位于包内；这里做一次轻量的本地文件头扫描
    private static func packageFromZip(data: Data) -> String? {
        let needle = [UInt8]("\"package\"".utf8)
        let bytes = [UInt8](data)
        guard !needle.isEmpty, bytes.count > needle.count else { return nil }
        var matchStart = -1
        for i in 0...(bytes.count - needle.count) {
            var ok = true
            for j in 0..<needle.count where bytes[i + j] != needle[j] { ok = false; break }
            if ok { matchStart = i + needle.count; break }
        }
        guard matchStart >= 0 else { return nil }
        let start = matchStart
        let end = min(start + 200, bytes.count)
        guard let text = String(bytes: bytes[start..<end], encoding: .utf8),
              let quoteStart = text.firstIndex(of: "\""),
              let restStart = text.index(quoteStart, offsetBy: 1, limitedBy: text.endIndex),
              let quoteEnd = text[restStart...].firstIndex(of: "\"") else { return nil }
        let value = String(text[restStart..<quoteEnd]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
