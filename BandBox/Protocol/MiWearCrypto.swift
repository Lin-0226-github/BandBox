//
//  MiWearCrypto.swift
//  BandBox
//
//  小米 Vela 穿戴协议（vela-v5）所需的密码学原语：
//    · HMAC-SHA256          —— 系统 CryptoKit（iOS 13+）
//    · HKDF-Expand-SHA256   —— 基于上述 HMAC 手工迭代（与 miwear 的 "miwear-auth" 派生一致）
//    · AES-128-CTR（IV = 会话密钥本身）
//    · AES-128-CCM（tag 4 字节，nonce 12 字节）—— CommonCrypto 不提供，这里基于块加密手写
//
//  全部经过 Python 参考实现（cryptography 库）逐字节交叉验证。
//

import Foundation
import CryptoKit

enum MiWearCrypto {

    // MARK: - HMAC / HKDF

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: symKey)
        return Data(code)
    }

    /// HKDF-Expand（RFC 5869），info 固定为 "miwear-auth"
    static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var out = Data()
        var prev = Data()
        var counter: UInt8 = 1
        while out.count < length {
            var input = Data()
            input.append(prev)
            input.append(info)
            input.append(counter)
            prev = hmacSHA256(key: prk, message: input)
            out.append(prev)
            if counter == 255 { break }
            counter += 1
        }
        return out.prefix(length)
    }

    /// vela-v5 会话密钥派生
    /// - hmacKey = HMAC-SHA256(key = phoneNonce || watchNonce, msg = authKey)
    /// - OKM     = HKDF-Expand(hmacKey, info = "miwear-auth", L = 64)
    /// - decKey  = OKM[0..16]   encKey = OKM[16..32]   decNonce = OKM[32..36]   encNonce = OKM[36..40]
    static func deriveKeys(authKey: Data, phoneNonce: Data, watchNonce: Data) -> SessionKeys {
        var initKey = Data()
        initKey.append(phoneNonce)
        initKey.append(watchNonce)
        let hmacKey = hmacSHA256(key: initKey, message: authKey)
        let okm = hkdfExpand(prk: hmacKey, info: Data("miwear-auth".utf8), length: 64)
        return SessionKeys(
            decKey: okm.subdata(in: 0..<16),
            encKey: okm.subdata(in: 16..<32),
            decNonce: okm.subdata(in: 32..<36),
            encNonce: okm.subdata(in: 36..<40)
        )
    }

    struct SessionKeys {
        let decKey: Data
        let encKey: Data
        let decNonce: Data
        let encNonce: Data
    }

    /// 校验手环返回的 HMAC：HMAC-SHA256(decKey, watchNonce || phoneNonce)
    static func verifyWatchHmac(decKey: Data, watchNonce: Data, phoneNonce: Data, received: Data) -> Bool {
        var msg = Data()
        msg.append(watchNonce)
        msg.append(phoneNonce)
        return hmacSHA256(key: decKey, message: msg) == received
    }

    /// 手机侧签名：HMAC-SHA256(encKey, phoneNonce || watchNonce)
    static func encryptedSigns(encKey: Data, phoneNonce: Data, watchNonce: Data) -> Data {
        var msg = Data()
        msg.append(phoneNonce)
        msg.append(watchNonce)
        return hmacSHA256(key: encKey, message: msg)
    }

    // MARK: - AES-128-CTR（CCM 模式前的通用工具）

    /// CTR 模式，计数器为 128 位大端整数（与 Python cryptography 的 modes.CTR 一致）
    static func aesCTR(key: Data, iv: Data, data: Data) -> Data {
        let aes = AES128(key: key)
        var counter = [UInt8](iv)
        if counter.count != 16 { counter = [UInt8](repeating: 0, count: 16) }
        var out = Data()
        out.reserveCapacity(data.count)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let ks = aes.encryptBlock(counter)
            let end = min(offset + 16, bytes.count)
            for i in offset..<end { out.append(bytes[i] ^ ks[i - offset]) }
            incrementCounter(&counter)
            offset += 16
        }
        return out
    }

    // MARK: - AES-128-CCM

    /// CCM 加密（nonce 12 字节 → L=3，tag 默认 4 字节，AAD 为空）
    static func aesCCMEncrypt(key: Data, nonce: Data, plaintext: Data, tagLength: Int = 4, aad: Data = Data()) -> Data {
        let aes = AES128(key: key)
        let nonceBytes = [UInt8](nonce)
        let L = 15 - nonceBytes.count
        precondition(L == 3, "vela-v5 使用 12 字节 nonce")
        let plainBytes = [UInt8](plaintext)

        // ---- CBC-MAC ----
        let flags = UInt8((aad.isEmpty ? 0x00 : 0x40) | (((tagLength - 2) / 2) << 3) | (L - 1))
        var b0 = [UInt8]()
        b0.append(flags)
        b0.append(contentsOf: nonceBytes)
        b0.append(contentsOf: bigEndian(UInt64(plainBytes.count), count: L))

        var macInput = [UInt8]()
        if !aad.isEmpty {
            let aadBytes = [UInt8](aad)
            macInput.append(contentsOf: bigEndian(UInt64(aadBytes.count), count: 2))
            macInput.append(contentsOf: pad16(aadBytes))
        }
        macInput.append(contentsOf: pad16(plainBytes))

        var x = aes.encryptBlock(b0)
        var offset = 0
        while offset < macInput.count {
            let chunkLen = min(16, macInput.count - offset)
            var block = x                       // 不足 16 字节的部分按 0 补齐：x ^ 0 = x
            for j in 0..<chunkLen { block[j] = x[j] ^ macInput[offset + j] }
            x = aes.encryptBlock(block)
            offset += 16
        }

        // ---- CTR 加密 ----
        let prefix = UInt8(L - 1)
        var a0 = [UInt8]()
        a0.append(prefix)
        a0.append(contentsOf: nonceBytes)
        a0.append(contentsOf: [0, 0, 0])
        let s0 = aes.encryptBlock(a0)

        var tag = [UInt8]()
        for i in 0..<tagLength { tag.append(x[i] ^ s0[i]) }

        var cipher = [UInt8]()
        cipher.reserveCapacity(plainBytes.count)
        var counter = 1
        offset = 0
        while offset < plainBytes.count {
            var ai = [UInt8]()
            ai.append(prefix)
            ai.append(contentsOf: nonceBytes)
            ai.append(contentsOf: bigEndian(UInt64(counter), count: L))
            let si = aes.encryptBlock(ai)
            let end = min(offset + 16, plainBytes.count)
            for i in offset..<end { cipher.append(plainBytes[i] ^ si[i - offset]) }
            counter += 1
            offset += 16
        }
        cipher.append(contentsOf: tag)
        return Data(cipher)
    }

    // MARK: - 工具

    private static func incrementCounter(_ c: inout [UInt8]) {
        var i = c.count - 1
        while i >= 0 {
            if c[i] == 0xFF {
                c[i] = 0
                i -= 1
            } else {
                c[i] += 1
                return
            }
        }
    }

    private static func pad16(_ b: [UInt8]) -> [UInt8] {
        let r = b.count % 16
        if r == 0 { return b }
        var o = b
        o.append(contentsOf: [UInt8](repeating: 0, count: 16 - r))
        return o
    }

    private static func bigEndian(_ value: UInt64, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var v = value
        var i = count - 1
        while i >= 0 {
            out[i] = UInt8(v & 0xFF)
            v >>= 8
            i -= 1
        }
        return out
    }
}
