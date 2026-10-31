# BandBox · 小米穿戴设备第三方工具箱（iOS 版）

一个面向 **小米 Vela 穿戴设备** 的第三方工具箱 App，实现类 AstroBox 的核心能力：通过蓝牙直连手环 / 手表，安装第三方表盘、快应用（rpk），管理已装资源，读取设备信息。

**最低系统：iOS 15.0**（已在工程里锁定 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`），无需越狱即可安装（配合 TrollStore）。

---

## 一、先说清楚：iOS 上能做什么、不能做什么

小米 Vela 设备（手环 9 / 10、REDMI Watch 5/6、小米 Watch S3/S4 等）对外有两条通道：

| 通道 | 说明 | iOS 能用吗 |
|---|---|---|
| **BLE（低功耗蓝牙 GATT）** | 引导通道，`fe95` 服务，特征 `5e` 写 / `5f` 通知 | ✅ 可以 |
| **SPP（经典蓝牙 RFCOMM，channel 5）** | 主数据通道，安卓与桌面端走它，免配对、速度快、连接稳定 | ❌ 需要苹果 MFi 授权 |

**iOS 只向第三方 App 开放 BLE，SPP 需要 MFi 认证**，所以本工具的全部通信都走 BLE。好消息是 **vela-v5 的帧格式在 BLE 与 SPP 上完全一致**（`A5 A5` 帧 + Command protobuf + Mass 通道），因此协议栈可以复用；代价是：

- 传输速度低于安卓 / 桌面端（BLE 分片更小，需要节流）；
- **部分机型在认证完成后会关闭 BLE**，表现为「刚连上就断」——需要重连或让手环进入「连接新手机」模式；
- iOS 上报的机型会让手环**隐藏快应用入口**，这就是 AstroBox 所谓的「安卓伪装模式」由来。本工具把该开关做进了设置页。

> 参考实现在 **小米手环 9（N66，固件 3.1.32）** 上验证通过。手环 8 及更早机型是 Zepp OS 旧协议，**不适用**。

---

## 二、功能

- 扫描并连接附近的小米穿戴设备
- **vela-v5 三步认证**（PhoneNonce / WatchNonce / HMAC-SHA256 + HKDF 派生会话密钥 + AES-CCM 设备信息）
- 设备信息（电量、序列号、固件版本、型号）+ 系统字段原始 dump
- 已安装应用列表与卸载
- **安装快应用（.rpk）**、**安装表盘（.bin）**、固件（实验性，默认提示风险）
- 传输参数可调（分块大小 / 发送间隔 / 上传 type），便于真机调试
- **安卓伪装**（上报机型切换），解决 iOS 下快应用被隐藏的问题
- 协议级日志（可过滤、可复制），排障的主要依据

---

## 三、编译

### 方式 A · GitHub Actions（不用 Mac，推荐）

仓库内置 `.github/workflows/build.yml`，push 到 `main` 或在 Actions 页手动触发即可自动编译，产出**未签名 IPA**：

1. 把仓库导入到自己的 GitHub 账号（Fork 或新建仓库后 push）；
2. 打开 **Actions → build-ipa → Run workflow**；
3. 跑完后在该次运行页面底部 **Artifacts** 下载 `BandBox-ipa-<run号>.zip`，解压得到 `.ipa`；
4. 给仓库打 tag（如 `v1.0`）会自动创建 Release 并把 IPA 挂上去。

流水线做的事：`xcodebuild build`（`CODE_SIGNING_ALLOWED=NO`，仅 arm64）→ 组装 `Payload/BandBox.app` → 打 zip → 校验 `Info.plist` 的 Bundle ID / MinimumOSVersion → 上传产物。另有一个 `test` job 在模拟器上跑协议层单元测试。

### 方式 B · 本机 Xcode

1. 用 **Xcode 14 及以上**打开 `BandBox.xcodeproj`。
2. 选中 `BandBox` target → **Signing & Capabilities**，把 Team 换成你自己的 Apple ID / 开发者账号（Bundle ID 可保持 `com.bandbox.ios` 或改成你自己的）。只想出未签名包的话，把 `CODE_SIGNING_ALLOWED` 设为 `NO` 即可跳过。
3. **无需**添加任何第三方依赖：AES-128 / CRC / protobuf 编解码均为工程内实现，HMAC 用系统 CryptoKit，无 bridging header。
4. `⌘R` 编译到真机（模拟器没有蓝牙，功能不可用）。
5. `⌘U` 可跑 `BandBoxTests`：里面包含一组由 Python 参考实现（hashlib / hmac / cryptography）预先算好的向量，能验证 CRC、AES、密钥派生、CTR/CCM、帧编解码、protobuf 构造是否全部正确。**建议真机调试前先跑一遍单元测试。**

---

## 四、安装到 iOS 15.5

App Store 不会上架这类工具，需要侧载。**iOS 15.5 正好落在 TrollStore 的支持范围内（iOS 14.0 – 16.6.1 / 17.0）**，可以永久签名、不用 7 天重签：

1. 拿到未签名 IPA（Actions 产物，或本机 `xcodebuild` 后自己打 `Payload/` 压缩包）。
2. 设备上安装 [TrollStore](https://github.com/opa334/TrollStore)（iOS 15.5 可用 TrollInstallerX / TrollHelperOTA，取决于芯片）。
3. 把 `.ipa` 通过「文件」App 或 Safari 分享给 TrollStore，选择 **Install**。TrollStore 会自己用 ldid 做伪签名，**不需要** Apple 开发者账号。

不想折腾 TrollStore 也可以用 AltStore / SideStore / Sideloadly 签名，但每 7 天需要重新签名一次。

---

## 五、使用步骤

### 1. 拿到 AuthKey（32 位十六进制）

AuthKey 存在「小米运动健康」App 里，跟随设备、不会自动过期。官方工具（AstroBox）推荐的做法是「导出迁移日志 → 用工具读日志」，本项目把这条路做全了：

**A. 安卓手机（最稳）**

1. 安装「小米运动健康」+「表盘自定义工具」（米坛社区 BandBBS）；
2. 用小米运动健康配对并同步，看到「设备数据同步成功」；
3. 「我的 → 关于」连续快速点击 App 图标约 10 次 → 弹出「迁移日志文件」→ 确定；
4. 表盘自定义工具 → 工具 → **AuthKey 读取工具** → 开始读取 → 复制。

**B. 电脑（不装第三方工具）**

把导出的日志包拿到电脑，用仓库里的工具解析：

```bash
python3 tools/extract_authkey.py 日志.zip          # 命令行，支持嵌套 zip
open tools/authkey.html                            # 或直接双击，网页本地解析，不上传
```

网页版需要 Chrome / Edge 或 Safari 16.4+（用到 `DecompressionStream`）；不满足就用 Python 脚本。两个工具都会打印设备名，多台设备时按名字挑。

> 拥有 AuthKey 就等于拥有手环蓝牙最高控制权，**不要外泄**。App 内只存在本机 `UserDefaults`，不会上传。

### 小米手环 10 NFC 版注意点

- NFC 版与标准版蓝牙协议完全一致，本工具不需要任何特殊处理；
- 「连接新手机」在 **设置 → 我的设备 → 连接新手机**（老机型在「系统操作」里）；
- 手环 10 会记住上一次绑定的手机，换机前先在原手机的「小米运动健康」里解绑，或直接在手环上执行「连接新手机」，否则认证一结束就会被踢下线；
- 抬腕亮屏/息屏状态下都可以连接，不需要点亮屏幕。

### 2. 配置

打开 App → 「设置」：

| 项目 | 建议值 |
|---|---|
| AuthKey | 32 位十六进制，格式正确时右侧出现绿色对勾 |
| 上报机型 | 安装资源时用 `iPhone`；想让快应用显示时切到安卓机型（安卓伪装） |
| 分块大小 | 默认 `244`；不稳定就降到 `128` |
| 发送间隔 | 默认 `70ms`；丢块就提到 `150ms` |

### 3. 连接

- 关闭其他已连接手环的 App（小米运动健康、其他表盘工具）；
- 若扫不到设备，到「小米运动健康 → 设备 → 连接新手机」让手环进入可配对窗口；
- 在「设备」页扫描并点击你的手环，等待「会话就绪」。

### 4. 安装资源

点击「安装快应用 / 安装表盘」选择本地 `.rpk` 或 `.bin` 文件：

- `.rpk` 的包名会自动从包内 `manifest.json` 的 `package` 字段解析；
- 表盘用文件名作为包名；
- 进度条走完后手环会异步写入，等几秒到几十秒再看。

---

## 六、排障

| 现象 | 处理 |
|---|---|
| 扫不到手环 | 进入「连接新手机」模式；关掉其他手环 App 后台；重开系统蓝牙 |
| HMAC 校验失败 | AuthKey 与设备不匹配，或该设备不是 vela-v5（手环 8 及更早不支持） |
| 连上就断 | 部分机型认证后关闭 BLE，重连或重启手环后再试 |
| 手环拒绝安装（cmd≠0） | 存储空间不足或资源不适配，先卸载几个资源 |
| 进度走完但看不到 | 等一会儿；iOS 机型会隐藏快应用，切到安卓伪装重连后再看 |
| 上传中途断开 | 减小分块大小、增大发送间隔 |

所有异常都会在「协议日志」里留下 `← type=… subtype=…` 的记录，复制出来对照 `PROTOCOL.md` 排查最有效。

---

## 七、工程结构

```
BandBox/
├── App/BandBoxApp.swift          # 入口
├── Protocol/                     # 协议栈（纯 Swift，无依赖）
│   ├── CRC16.swift               # CRC-16/ARC
│   ├── AES128.swift              # AES-128 块加密（手写，供 CTR/CCM 使用）
│   ├── MiWearCrypto.swift        # HMAC/HKDF 派生 + AES-CTR + AES-CCM
│   ├── Protobuf.swift            # 极简 protobuf 编解码
│   ├── MiWearPacket.swift        # A5A5 帧编解码 + 流式解帧
│   ├── MiWearCommand.swift       # Command / Auth / Rpk / DataUpload
│   └── Data+Extensions.swift     # hex 互转
├── Bluetooth/
│   ├── BLETransport.swift        # CoreBluetooth 封装（扫描/连接/发现/读写）
│   └── MiWearSession.swift       # 认证 + 命令 + Mass 上传 + CRC32
├── Services/                     # 设置存储、业务编排、AuthKey 提取
├── Views/                        # SwiftUI 界面（iOS 15 兼容 API）
├── Resources/                    # Info.plist / Assets
├── tools/
│   ├── extract_authkey.py        # 从运动健康日志提取 AuthKey（命令行）
│   └── authkey.html              # 同上，浏览器本地解析
└── .github/workflows/build.yml   # GitHub Actions：测 -> 编译 -> 未签名 IPA
```

协议细节见 [`PROTOCOL.md`](PROTOCOL.md)。

---

## 八、许可与免责

- 本工程代码采用 **MIT** 许可。协议实现参考了公开逆向成果与 MIT 许可的 [`xiaomi-band9-mcp`](https://github.com/Soodok/xiaomi-band9-mcp) 协议文档，未使用任何 AGPL 代码。
- **本工具与小米官方无关**。刷写固件、强装不适配的资源存在损坏设备的风险（触发看门狗重启、界面渲染异常等），请自行承担。
- 请仅安装来自可信来源、与机型匹配的资源，注意第三方资源的版权。
