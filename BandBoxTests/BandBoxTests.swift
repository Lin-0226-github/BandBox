//
//  BandBoxTests.swift
//  BandBoxTests
//
//  协议栈单元测试。所有期望值均由 Python 参考实现（hashlib / hmac / cryptography）
//  预先计算，用于在真机调试前先确认密码学与编解码部分无误。
//

import XCTest
@testable import BandBox

final class BandBoxTests: XCTestCase {

    // MARK: - 固定输入

    private let authKey    = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
    private let phoneNonce = Data(hexString: "101112131415161718191a1b1c1d1e1f")!
    private let watchNonce = Data(hexString: "202122232425262728292a2b2c2d2e2f")!

    // MARK: - CRC

    func testCRC16() {
        XCTAssertEqual(CRC16.arc(Data()), 0x0000)
        XCTAssertEqual(CRC16.arc(Data(hexString: "01020100")!), 0xACA1)
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.compute(Data("123456789".utf8)), 0xCBF43926)
        var bytes = Data()
        for _ in 0..<4 {
            for v in 0..<256 { bytes.append(UInt8(v)) }
        }
        XCTAssertEqual(bytes.count, 1024)
        XCTAssertEqual(CRC32.compute(bytes), 0xB70B4C26)
    }

    // MARK: - AES

    func testAESBlockFIPS197() {
        let aes = AES128(key: Data(hexString: "000102030405060708090a0b0c0d0e0f")!)
        let out = aes.encryptBlock(Data(hexString: "00112233445566778899aabbccddeeff")!)
        XCTAssertEqual(out.hexString, "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    func testAESBlockNIST() {
        let aes = AES128(key: Data(hexString: "2b7e151628aed2a6abf7158809cf4f3c")!)
        let out = aes.encryptBlock(Data(hexString: "6bc1bee22e409f96e93d7e117393172a")!)
        XCTAssertEqual(out.hexString, "3ad77bb40d7a3660a89ecaf32466ef97")
    }

    func testAESBlockSessionKey() {
        let aes = AES128(key: Data(hexString: "923e295e02aecb7619a8e1b9f574c988")!)
        let out = aes.encryptBlock(Data(count: 16))
        XCTAssertEqual(out.hexString, "5dcf6c71f28966b654e4710a44bb9da3")
    }

    // MARK: - 密钥派生

    func testDeriveKeys() {
        let keys = MiWearCrypto.deriveKeys(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
        XCTAssertEqual(keys.decKey.hexString,   "d738074e6570abb50d001db70f497a37")
        XCTAssertEqual(keys.encKey.hexString,   "923e295e02aecb7619a8e1b9f574c988")
        XCTAssertEqual(keys.decNonce.hexString, "8676d225")
        XCTAssertEqual(keys.encNonce.hexString, "23869a15")
    }

    func testWatchHmac() {
        let keys = MiWearCrypto.deriveKeys(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
        let expected = Data(hexString: "17aa8eecac21d9d71cba6ea653d126d77abc2f4d0357f1cce01d433d40e42235")!
        XCTAssertTrue(
            MiWearCrypto.verifyWatchHmac(decKey: keys.decKey,
                                         watchNonce: watchNonce,
                                         phoneNonce: phoneNonce,
                                         received: expected)
        )
        XCTAssertEqual(
            MiWearCrypto.encryptedSigns(encKey: keys.encKey, phoneNonce: phoneNonce, watchNonce: watchNonce).hexString,
            "7e6e4d786282c1af4441b2ed315da93c8ae2c820a72df584d62315d73913a9dc"
        )
    }

    // MARK: - AES-CTR / CCM

    func testAESCTR() {
        let key = Data(hexString: "923e295e02aecb7619a8e1b9f574c988")!
        let plaintext = Data(hexString: "4135413541354135413541354135413541354135413541354135413541354135")!
        let out = MiWearCrypto.aesCTR(key: key, iv: key, data: plaintext)
        XCTAssertEqual(out.hexString, "fed10109318d38811dacba90009c0800abc6727f7c0547ce5bf8059e1755776b")
        // CTR 是对合运算
        XCTAssertEqual(MiWearCrypto.aesCTR(key: key, iv: key, data: out), plaintext)
    }

    func testAESCCM() {
        let key = Data(hexString: "923e295e02aecb7619a8e1b9f574c988")!
        let nonce = Data(hexString: "23869a150000000000000000")!
        let plaintext = Data(hexString: "080015000010421a06504c5a31313020e6ad800c2a02434e")!
        let out = MiWearCrypto.aesCCMEncrypt(key: key, nonce: nonce, plaintext: plaintext, tagLength: 4)
        XCTAssertEqual(out.hexString, "806dad1c239f04c0437a027abe1c94b6561390eac2b2e7338c933848")
        XCTAssertEqual(out.count, plaintext.count + 4)
    }

    // MARK: - 帧

    func testFrameEncode() {
        let ack = MiWearPacket.encode(type: PacketType.ack.rawValue, seq: 7, body: Data())
        XCTAssertEqual(ack.hexString, "a5a5010700000000")

        let body = Data(hexString: "01010801101a1a12f201100a10101112131415161718191a1b1c1d1e1f")!
        let frame = MiWearPacket.encode(type: PacketType.data.rawValue, seq: 0, body: body)
        XCTAssertEqual(frame.hexString,
                       "a5a503001d0029d401010801101a1a12f201100a10101112131415161718191a1b1c1d1e1f")
    }

    func testStreamParserReassembly() {
        let parser = PacketStreamParser()
        let body = Data(hexString: "01010801101a1a")!
        var frame = MiWearPacket.encode(type: PacketType.data.rawValue, seq: 3, body: body)
        let all = Data(frame)
        // 模拟 BLE 分片：一次只送 5 个字节
        var packets: [MiWearPacket] = []
        var offset = 0
        while offset < all.count {
            let end = min(offset + 5, all.count)
            parser.append(Data(all[offset..<end]))
            packets.append(contentsOf: parser.drain())
            offset = end
        }
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.seq, 3)
        XCTAssertEqual(packets.first?.body, body)
    }

    func testPacketFields() {
        let payload = Data(hexString: "080114")!
        let frame = MiWearPacket.data(channel: .mass, opcode: .plain, seq: 9, payload: payload)
        let parser = PacketStreamParser()
        parser.append(frame)
        let packet = parser.drain().first!
        XCTAssertEqual(packet.channel, Channel.mass.rawValue)
        XCTAssertEqual(packet.opcode, OpCode.plain.rawValue)
        XCTAssertEqual(packet.payload, payload)
    }

    // MARK: - Protobuf

    func testVarint() {
        XCTAssertEqual(PB.varint(0).hexString, "00")
        XCTAssertEqual(PB.varint(127).hexString, "7f")
        XCTAssertEqual(PB.varint(300).hexString, "ac02")
    }

    func testCommandStructure() {
        // Command{type=20, subtype=0}
        XCTAssertEqual(MiWearCommand.listApps().hexString, "08141000")
        // Command{type=2, subtype=1}
        XCTAssertEqual(MiWearCommand.battery().hexString, "08021001")
        // Command{type=2, subtype=2}
        XCTAssertEqual(MiWearCommand.deviceInfo().hexString, "08021002")
    }

    func testAuthStep1() {
        let cmd = MiWearCommand.authStep1(phoneNonce: phoneNonce)
        // Auth{ phoneNonce{ nonce } }：field30 的 tag 为 0xF2（30<<3|2），长度 21
        XCTAssertEqual(cmd.hexString, "0801101a1a15f201120a10101112131415161718191a1b1c1d1e1f")
        let fields = PB.parse(cmd)
        XCTAssertEqual(fields.firstVarint(1), 1)
        XCTAssertEqual(fields.firstVarint(2), 26)
    }

    func testAuthDeviceInfoUsesFixed32() {
        let info = MiWearCommand.authDeviceInfo(model: "PLZ110", capability: 25_171_686, region: "CN")
        XCTAssertEqual(info.hexString, "080015000010421a06504c5a31313020e6ad800c2a02434e")
        let fields = PB.parse(info)
        XCTAssertEqual(fields.firstVarint(1), 0)
        XCTAssertEqual(fields.firstString(3), "PLZ110")
        XCTAssertEqual(fields.firstVarint(4), 25_171_686)
        XCTAssertEqual(fields.firstString(5), "CN")
    }

    func testInstallRequest() {
        let cmd = MiWearCommand.installApp(package: "com.demo.hello", size: 123_456)
        let fields = PB.parse(cmd)
        XCTAssertEqual(fields.firstVarint(1), 20)
        XCTAssertEqual(fields.firstVarint(2), 1)
        let rm = PB.parse(fields.firstBytes(22)!)
        let info = PB.parse(rm.firstBytes(2)!)
        XCTAssertEqual(info.firstString(1), "com.demo.hello")
        XCTAssertEqual(info.firstVarint(2), 3)          // unknown2 恒为 3
        XCTAssertEqual(info.firstVarint(3), 123_456)    // size 在 field3
    }

    func testDataUploadRequest() {
        let md5 = Data(hexString: "b2ea9f7fcea831a4a63b213f41a8855b")!
        let cmd = MiWearCommand.dataUploadRequest(md5: md5, size: 1024)
        let fields = PB.parse(cmd)
        XCTAssertEqual(fields.firstVarint(1), 22)
        let du = PB.parse(fields.firstBytes(24)!)
        let req = PB.parse(du.firstBytes(1)!)
        XCTAssertEqual(req.firstVarint(1), 64)
        XCTAssertEqual(req.firstBytes(2), md5)
        XCTAssertEqual(req.firstVarint(3), 1024)
    }

    func testParseAppList() throws {
        // 构造一个 rpkList 响应再解析回来
        var item = Data()
        item += PB.string(1, "com.demo.hello")
        item += PB.bytes(2, Data(hexString: "0102030405")!)
        item += PB.string(5, "Hello")
        let list = PB.bytes(1, item)
        let message = PB.bytes(1, list)
        // rpkMessage 放入 Command 的 field22
        var command = PB.uint(1, 20)
        command += PB.uint(2, 0)
        command += PB.bytes(22, message)

        let parsed = MiWearCommand.parseAppList(PB.parse(command))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.package, "com.demo.hello")
        XCTAssertEqual(parsed.first?.name, "Hello")
        XCTAssertEqual(parsed.first?.sha.hexString, "0102030405")
    }

    // MARK: - 端到端：构造一次完整的安装握手（不发蓝牙，只验证字节）

    func testInstallHandshakeBytes() {
        let keys = MiWearCrypto.deriveKeys(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce)
        let cmd = MiWearCommand.installApp(package: "com.demo.hello", size: 4096)
        let encrypted = MiWearCrypto.aesCTR(key: keys.encKey, iv: keys.encKey, data: cmd)
        let frame = MiWearPacket.data(channel: .pb, opcode: .encrypted, seq: 2, payload: encrypted)

        // 手环侧解密后应还原出原始命令
        let parser = PacketStreamParser()
        parser.append(frame)
        let packet = parser.drain().first!
        XCTAssertEqual(packet.channel, Channel.pb.rawValue)
        XCTAssertEqual(packet.opcode, OpCode.encrypted.rawValue)
        // 手机用 encKey 加密，手环用同一把 encKey 解密（CTR 为对合运算）
        let decrypted = MiWearCrypto.aesCTR(key: keys.encKey, iv: keys.encKey, data: packet.payload)
        XCTAssertEqual(decrypted, cmd)
        // 手环回包则由手机用 decKey 解密
        let echo = MiWearCrypto.aesCTR(key: keys.decKey, iv: keys.decKey, data: cmd)
        XCTAssertEqual(MiWearCrypto.aesCTR(key: keys.decKey, iv: keys.decKey, data: echo), cmd)
    }

    // MARK: - 工具

    func testHexStringRoundTrip() {
        let original = Data([0x00, 0x1f, 0xa5, 0xa5, 0xff])
        XCTAssertEqual(Data(hexString: original.hexString), original)
        XCTAssertNil(Data(hexString: "abc"))            // 奇数长度
        XCTAssertNil(Data(hexString: "zz"))             // 非十六进制
    }
}
