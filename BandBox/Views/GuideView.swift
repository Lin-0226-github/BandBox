//
//  GuideView.swift
//  BandBox
//
//  上手指引与协议说明
//

import SwiftUI

struct GuideView: View {
    var body: some View {
        NavigationView {
            List {
                stepsSection
                channelSection
                faqSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("使用指引")
        }
    }

    private var stepsSection: some View {
        Section {
            step(1, "准备 AuthKey", "用安卓手机装「小米运动健康」+「表盘自定义工具」：同步设备 → 我的/关于 连点 Logo 10 次生成日志 → 表盘自定义工具「AuthKey 读取工具」读出 32 位密钥。详见「设置 → 如何获取 AuthKey」。")
            step(2, "让手环进入可配对窗口", "小米手环 10：设置 → 我的设备 → 连接新手机。老机型是：设置 → 系统操作 → 连接新手机。这是连不上的第一大原因。")
            step(3, "填入并连接", "在「设置」粘贴 AuthKey，回到「设备」页扫描并选择你的手环；连接过程中手环会弹出配对确认，点「同意」。")
            step(4, "安装资源", "点击「安装快应用 / 安装表盘」选择本地 .rpk 或 .bin 文件。进度条走完后手环会异步写入，稍等几秒。")
            step(5, "装完看不到？", "iOS 上报机型会让手环隐藏快应用。到「设置 → 设备身份」切换成安卓机型（安卓伪装）后重新连接，快应用就会重新出现。")
        } header: {
            Text("五步上手")
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(n)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                Text(title).font(.subheadline.bold())
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var channelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("为什么 iOS 比安卓慢、更容易断", systemImage: "bolt.horizontal")
                    .font(.subheadline.bold())
                Text("小米 Vela 设备有两条通道：BLE（引导/配对）与经典蓝牙 SPP（主数据通道，安卓与桌面端走它）。iOS 只对第三方 App 开放 BLE，SPP 需要苹果 MFi 授权，所以本工具全部走 BLE。vela-v5 的帧格式在两条通道上完全一致，但部分机型会在认证完成后关闭 BLE，表现为「刚连上就断」。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Label("已验证 / 未验证", systemImage: "checkmark.seal")
                    .font(.subheadline.bold())
                Text("参考实现在小米手环 9（N66，固件 3.1.32）上验证通过。手环 9 系列、手环 10 系列（含 NFC 版）、REDMI Watch 5/6、小米 Watch S3/S4/S5 属同一协议族；手环 8 及更早机型为 Zepp OS 旧协议，不适用本工具。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Label("小米手环 10 NFC 版专项", systemImage: "wave.3.right")
                    .font(.subheadline.bold())
                Text("NFC 版与标准版蓝牙协议一致，本工具不受影响。注意两点：① 手环 10 的「连接新手机」在「设置 → 我的设备」里；② 手环 10 默认会拒绝未在「小米运动健康」中解绑的旧手机，换机前先在原手机解绑或直接在手环上执行「连接新手机」，否则认证阶段会被立刻断开。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("通道与协议")
        }
    }

    private var faqSection: some View {
        Section {
            faq("扫不到手环", "确认手环未被其他手机占用；进入小米运动健康的「连接新手机」；关闭其他手环类 App 的后台；系统蓝牙开关重新打开一次。")
            faq("HMAC 校验失败", "AuthKey 与设备不匹配，或该设备不是 vela-v5 协议（手环 8 及更早机型不支持）。")
            faq("手环拒绝安装 cmd≠0", "通常是存储空间不足或资源包与机型不适配。先卸载几个不用的资源再试。")
            faq("进度走完但没出现", "手环异步写入需要几秒到几十秒；也可检查是否因 iOS 机型标识被隐藏（用安卓伪装连接后再看）。")
            faq("上传中途断开", "减小分块大小、增大发送间隔；部分机型在 BLE 上无法维持长时间大流量传输。")
        } header: {
            Text("常见问题")
        }
    }

    private func faq(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q).font(.subheadline.bold())
            Text(a).font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }
}
