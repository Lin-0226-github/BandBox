//
//  AuthKeyGuideView.swift
//  BandBox
//
//  AuthKey 获取指引。流程对齐 AstroBox 官方教程：
//  小米运动健康同步设备 → 关于页连点 Logo 生成迁移日志 → 表盘自定义工具读取
//

import SwiftUI

struct AuthKeyGuideView: View {
    var body: some View {
        List {
            introSection
            androidSection
            desktopSection
            tipsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("如何获取 AuthKey")
    }

    private var introSection: some View {
        Section {
            Text("AuthKey 是手环蓝牙通道的 16 字节凭证，每台设备唯一。没有它，手环会拒绝一切读写请求（表现为认证阶段 HMAC 校验失败）。它保存在你手机上的「小米运动健康」里，所以只能从那里取，不能靠猜。")
                .font(.callout)
            Label("拿到后请勿外发：等同手环的蓝牙最高权限", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.orange)
        } header: {
            Text("它是什么")
        }
    }

    private var androidSection: some View {
        Section {
            step(1, "准备一台安卓手机", "安装「小米运动健康」和「表盘自定义工具」（米坛社区 BandBBS 可下载）。iOS 端无法读取自己的日志，所以这一步必须用安卓机。")
            step(2, "用小米运动健康配对并同步", "打开小米运动健康 → 设备，等待出现「设备数据同步成功」。若手环已绑在别的手机，先在手环上进入「连接新手机」。")
            step(3, "打开「我的 → 关于」连点 Logo", "连续快速点击「小米运动健康」图标 10 次左右，弹出「迁移日志文件」提示后点确定，等待日志生成完成。")
            step(4, "用表盘自定义工具读取", "打开表盘自定义工具 → 底部「工具」→「AuthKey 读取工具」→ 滑到底部点「开始读取」，出现 32 位字母数字组合即成功，点右侧复制。")
            step(5, "粘贴回 BandBox", "回到本 App 的「设置 → 设备凭证」，粘贴后点「从剪贴板提取」。格式校验通过（绿色对勾）即可去「设备」页连接。")
        } header: {
            Text("方案 A · 安卓手机（官方推荐）")
        } footer: {
            Text("来源：AstroBox 官方文档与米坛社区教程，2026 年 2 月仍有效。")
        }
    }

    private var desktopSection: some View {
        Section {
            Text("如果不想装第三方工具，可以把「小米运动健康」导出的日志文件拷到电脑，用项目自带的脚本解析：")
                .font(.callout)
            code("python3 tools/extract_authkey.py 日志.zip")
            Text("脚本会遍历压缩包内所有文本，按 authKey / auth_key 等字段名匹配 32 位十六进制，并打印设备名与 MAC，方便区分多台设备。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("方案 B · 电脑解析导出日志")
        }
    }

    private var tipsSection: some View {
        Section {
            faq("读取失败 / 读到全 0", "先确认第 2 步已「同步成功」，日志里才有设备会话记录；换一台设备或重新配对后再导出一次。")
            faq("换手机后要重新获取吗", "不需要。AuthKey 跟随设备，只要没在「小米运动健康」里删除设备就一直有效。")
            faq("提示 HMAC 校验失败", "Key 少一位 / 混入了别的设备。手环 10 系列与其他手环的 Key 不通用。")
            faq("能不能登录小米账号自动同步", "AstroBox 桌面端/安卓端支持该方式（走小米云接口）。iOS 端需要完整的小米账号登录与二次验证，本版本未实现，请走方案 A/B。")
        } header: {
            Text("常见问题")
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

    private func faq(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q).font(.subheadline.bold())
            Text(a).font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func code(_ s: String) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
    }
}
