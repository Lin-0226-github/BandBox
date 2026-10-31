//
//  AuthKeyExtractor.swift
//  BandBox
//
//  从「小米运动健康」导出的日志 / 用户粘贴的文本中提取 AuthKey。
//  日志里的形态并不统一，实测出现过：
//    authKey=0123456789abcdef0123456789abcdef
//    "authKey":"0123456789abcdef0123456789abcdef"
//    auth_key: 0123456789abcdef0123456789abcdef
//  因此这里按「先精确字段、后邻近推断」的顺序多轮匹配。
//

import Foundation

enum AuthKeyExtractor {

    /// 从任意文本中提取 32 位十六进制 AuthKey；找不到返回 nil
    static func extract(from text: String) -> String? {
        guard !text.isEmpty else { return nil }

        // 1) 明确的字段名 + 32 位十六进制
        let explicitPatterns = [
            #"(?i)auth[_\s-]?key["']?\s*[:=]\s*["']?([0-9a-f]{32})"#,
            #"(?i)"authkey"\s*:\s*"([0-9a-f]{32})""#,
            #"(?i)(?:device|bind|ble|login)[_\s-]?key["']?\s*[:=]\s*["']?([0-9a-f]{32})"#
        ]
        for pattern in explicitPatterns {
            if let value = firstGroup(pattern, in: text) { return value.lowercased() }
        }

        // 2) 兜底：整段里出现 32 位十六进制，且附近 60 字符内提到 key/auth
        let ns = text as NSString
        let regex = try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{32}\b"#)
        var fallback: String?
        regex?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let m = match else { return }
            let start = max(0, m.range.location - 60)
            let end = min(ns.length, NSMaxRange(m.range) + 60)
            let context = ns.substring(with: NSRange(location: start, length: end - start)).lowercased()
            if context.contains("auth") || context.contains("key") || context.contains("secret") {
                fallback = ns.substring(with: m.range).lowercased()
                stop.pointee = true
            }
        }
        return fallback
    }

    /// 是否为合法的 32 位十六进制
    static func isValid(_ hex: String) -> Bool {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 32 else { return false }
        return trimmed.allSatisfy { $0.isHexDigit }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }
}
