# vela-v5 协议速查（BandBox 实现版）

> 本协议为社区逆向成果，与小米运动健康 / AstroBox 同源。本文记录 BandBox 中实际用到的部分，
> 便于真机调试时对照日志排查。已在小米手环 9（N66，固件 3.1.32）上验证。

## 1. 通道

| 通道 | 用途 | iOS |
|---|---|---|
| BLE `fe95` | 特征 `5e` 写（RX）、`5f` 通知（TX） | ✅ 唯一可用 |
| SPP RFCOMM ch5 | 主数据通道，安卓/桌面端使用 | ❌ 需 MFi |

**两种通道上的帧格式完全一致**。iOS 只能走 BLE，代价是分片更小、需要节流，且部分机型认证后会关闭 BLE。

## 2. 帧格式（A5 A5）

```
[A5 A5] [type u8] [seq u8] [len u16 LE] [crc16 u16 LE] [body...]
  magic   1=Ack    序号     body 长度     CRC16-ARC     payload
          2=SessionConfig
          3=Data
```

- CRC16-ARC（poly 0xA001 反射，init 0），**只对 body 计算**
- Data 帧 body = `[channel u8][opcode u8][payload]`
  - channel：`1`=Pb（命令） / `2`=Mass（文件数据） / `6`=OTA / `7`=NetWork
  - opcode：`1`=Plain / `2`=Encrypted（AES-128-CTR）
- **每收到一个 Data 帧都必须立即回 Ack**（type=1，seq 相同），否则协议不推进
- BLE 的 notify 会把一帧切成多片送达，需按帧头 `len` 重组（工程内 `PacketStreamParser`）

### SessionConfig（连接后第一帧）

```
a5a5020016001d4d0101030001000002020000fc03020020000402001027
```

> ⚠️ 不要发 `BA DC FE` 开头的旧协议 hello，手环 9 收到即断开。

## 3. 认证（三步）

```
message Command {
  uint32 type = 1;      // 1=Account 2=System 20=Rpk 22=DataUpload 101=通用
  uint32 subtype = 2;
  Auth   auth = 3;
  bytes  rpkMessage = 22;
  bytes  dataUpload = 24;
  uint32 status = 100;
}
message Auth {
  PhoneNonce { bytes nonce = 1; }                                  phoneNonce = 30;
  WatchNonce { bytes nonce = 1; bytes hmac = 2; }                  watchNonce = 31;
  AuthStep3  { bytes encryptedNonces = 1; bytes encryptedDeviceInfo = 2; }  authStep3 = 32;
}
```

**Step1**（明文，Channel.Pb，seq=0）
→ `Command{type=1, subtype=26, auth{phoneNonce{16B 随机}}}`
← `Command{type=1, subtype=26, auth{watchNonce{16B nonce, 32B hmac}}}`

**密钥派生**

```
hmac_key = HMAC-SHA256(key = phoneNonce || watchNonce, msg = authKey)
OKM      = HKDF-Expand(hmac_key, info = "miwear-auth", L = 64)
decKey = OKM[0:16]   encKey = OKM[16:32]   decNonce = OKM[32:36]   encNonce = OKM[36:40]
```

校验：`watchNonce.hmac == HMAC-SHA256(decKey, watchNonce || phoneNonce)`（顺序是 **w‖p**）

**Step3**（明文帧承载 CCM 密文，seq=1）
→ `Command{type=1, subtype=27, auth{authStep3{
     encryptedNonces     = HMAC-SHA256(encKey, phoneNonce || watchNonce)          // 32B
     encryptedDeviceInfo = AES-CCM(encKey, nonce = encNonce || u32(0) || u32(0),   // 12B
                                   tag = 4B, aad = 空, 明文 = AuthDeviceInfo)
   }}}`

```
message AuthDeviceInfo {
  varint  field1 = 0            // 必须显式序列化为 0
  fixed32 field2 = 36.0         // ★ float！写成 varint 手环会拒绝
  string  field3 = "iPhone"     // 上报机型 → 决定手环是否隐藏快应用（安卓伪装）
  varint  field4 = 25171686     // capability
  string  field5 = "CN"
}
```

← DeviceConfirm。**收到后必须回 Ack**，否则认证不落地。

**认证之后**：所有命令 body 用 `AES-128-CTR(key=encKey, iv=encKey)` 加密，opcode=2；
手环回包用 **decKey** 解密（iv 同样是 decKey）。

## 4. 常用命令

| 功能 | 命令 |
|---|---|
| 电量 | `Command{type=2, subtype=1}` |
| 设备信息 | `Command{type=2, subtype=2}` |
| 应用列表 | `Command{type=20, subtype=0}` |
| 安装请求 | `Command{type=20, subtype=1, rpkMessage{rpkInfo{id=包名, unknown2=3, size=文件字节数}}}` |
| 卸载 | `Command{type=20, subtype=3, rpkMessage{rpkDel{id=包名, sha=列表查到的签名}}}` |
| 上传请求 | `Command{type=22, subtype=0, dataUpload{dataUploadRequest{type=64, md5sum=16B, size}}}` |

响应要点：

- `rpkInstallStart{cmd}`，**cmd == 0 才是批准**，非 0 表示拒绝（存储空间不足 / 包不适配）
- `dataUploadAck{md5sum, resumePosition, chunkSize}`
- ⚠️ `Command{type=101}` 的 `{status=1}` 是「通用命令接受」回执，**不代表批准安装**

## 5. 文件上传（Mass 通道）

```
完整数据块 = 00 | type(64) | md5(16B) | length(u32 LE) | 文件数据 | crc32(u32 LE)
                                                        └ crc 覆盖前面全部字节
分帧       = [channel=2][opcode=1] u16(总块数) u16(块号，从 1 起) 分片
```

- ★ **文件必须走 channel=2 (Mass)**。用 Pb（channel=1）传文件，手环会静默丢弃：
  批准、ACK 全都正常，但安装永远不生效 —— 这是最难排查的坑。
- 分片大小：SPP 上实测小米运动健康 880、AstroBox 977；BLE 上建议 128–244。
- **块间必须节流**（默认 70ms），灌太快手环丢块且无任何报错。
- 批准后必须在毫秒级内发出上传请求并开始传数据，中途停顿 3 秒以上手环会丢弃会话。
- 传完后手环异步写 flash，几秒到几十秒后重新拉列表才可见。

## 6. 参考实现对照

| 实现 | 通道 | 特征 |
|---|---|---|
| 小米运动健康 | SPP | mtu 16394，应用层帧 ≤880 |
| AstroBox | SPP | max_frame 977，SAR 流控 |
| 表盘自定义工具 | BLE | 242B 分片 + `Command{type=20}` 体系 |
| **BandBox（本工程）** | **BLE** | 分片可调（默认 244），节流可调（默认 70ms） |

## 7. 已知限制

- 仅在手环 9（N66 / FW 3.1.32）实测；同代 N67、手环 10 理论同源但字段可能微调
- `Command{type=101}` 的系统初始化序列（通讯录 / 能力同步）未实现，不影响安装
- 手环安装器偶发「病态」（命令全部正常响应但安装不执行），重启手环可恢复
- AuthKey 即手环蓝牙最高权限，注意保管
