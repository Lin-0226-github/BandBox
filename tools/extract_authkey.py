#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从「小米运动健康」导出的日志中提取 AuthKey。

用法：
    python3 tools/extract_authkey.py 日志.zip
    python3 tools/extract_authkey.py ./导出目录
    python3 tools/extract_authkey.py logcat.txt --json

支持 zip（含嵌套 zip）、gz、以及纯文本；会同时尝试 UTF-8 / UTF-16。
不联网，不上传，纯本地解析。
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import re
import sys
import zipfile
from typing import Iterable

# 明确的字段名：authKey / auth_key / "authKey":"..." 等
EXPLICIT = [
    re.compile(r'"?auth[_\s-]?key"?\s*[:=]\s*"?([0-9a-fA-F]{32})\b', re.I),
    re.compile(r'"(?:device|bind|ble|login)[A-Za-z_]*[Kk]ey"\s*:\s*"([0-9a-fA-F]{32})"'),
]
# 兜底：任意 32 位十六进制，且上下文出现 key/auth/secret
GENERIC = re.compile(r'\b[0-9a-fA-F]{32}\b')

MAX_BYTES = 200 * 1024 * 1024  # 单文件上限，避免误读巨大文件


def decode(raw: bytes) -> str:
    for enc in ("utf-8", "utf-16-le", "utf-16-be", "latin-1"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, UnicodeError):
            continue
    return raw.decode("utf-8", errors="ignore")


def iter_blobs(path: str) -> Iterable[tuple[str, bytes]]:
    """递归展开 zip / gz / 普通文件，产出 (来源名, 字节)"""
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for name in files:
                yield from iter_blobs(os.path.join(root, name))
        return

    if not os.path.isfile(path):
        return
    if os.path.getsize(path) > MAX_BYTES:
        print(f"[跳过] 文件过大：{path}", file=sys.stderr)
        return

    with open(path, "rb") as f:
        raw = f.read()

    yield from iter_blobs_bytes(path, raw)


def iter_blobs_bytes(name: str, raw: bytes) -> Iterable[tuple[str, bytes]]:
    """按魔数判断：gzip / zip 继续展开，其余当作文本产出"""
    if len(raw) < 4:
        return

    if raw[:2] == b"\x1f\x8b":
        try:
            yield from iter_blobs_bytes(name + "!gz", gzip.decompress(raw))
        except OSError:
            print(f"[跳过] 无法解压 gzip：{name}", file=sys.stderr)
        return

    if zipfile.is_zipfile(io.BytesIO(raw)):
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    try:
                        yield from iter_blobs_bytes(f"{name}!{info.filename}", zf.read(info))
                    except (RuntimeError, zipfile.BadZipFile, OSError) as exc:
                        print(f"[跳过] {info.filename}: {exc}", file=sys.stderr)
        except zipfile.BadZipFile:
            print(f"[跳过] 损坏的 zip：{name}", file=sys.stderr)
        return

    yield name, raw


def find_keys(text: str) -> list[tuple[str, str]]:
    """返回 [(authkey, 命中片段)]"""
    hits: list[tuple[str, str]] = []
    seen: set[str] = set()

    for pattern in EXPLICIT:
        for m in pattern.finditer(text):
            key = m.group(1).lower()
            if key not in seen:
                seen.add(key)
                hits.append((key, m.group(0)[:120]))

    if hits:
        return hits

    for m in GENERIC.finditer(text):
        start, end = max(0, m.start() - 80), min(len(text), m.end() + 80)
        ctx = text[start:end]
        low = ctx.lower()
        if any(w in low for w in ("auth", "key", "secret", "token")):
            key = m.group(0).lower()
            if key not in seen:
                seen.add(key)
                hits.append((key, ctx.replace("\n", " ")[:120]))
    return hits


def guess_device(text: str) -> str | None:
    """尽量从日志里找设备名，方便区分多台设备"""
    for pat in (
        r'"(?:deviceName|devName|name)"\s*:\s*"([^"]{2,40})"',
        r'deviceName["\']?\s*[:=]\s*["\']?([A-Za-z0-9][A-Za-z0-9 \-_.]{0,38}?)(?=\s+[A-Za-z]+[=:]|\s*$)',
    ):
        m = re.search(pat, text, re.I)
        if m:
            return m.group(1).strip()
    if re.search(r'band\s*10|smart\s*band\s*10', text, re.I):
        return "Xiaomi Smart Band 10"
    if re.search(r'band\s*9', text, re.I):
        return "Xiaomi Smart Band 9"
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="从小米运动健康日志中提取 AuthKey")
    ap.add_argument("path", help="日志文件 / zip / 目录")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出，便于脚本调用")
    args = ap.parse_args()

    if not os.path.exists(args.path):
        print(f"路径不存在：{args.path}", file=sys.stderr)
        return 2

    results: list[dict] = []
    for name, raw in iter_blobs(args.path):
        if not raw:
            continue
        text = decode(raw)
        if "auth" not in text.lower() and "key" not in text.lower():
            continue
        for key, ctx in find_keys(text):
            results.append({
                "authKey": key,
                "device": guess_device(text),
                "source": name,
                "context": ctx.strip(),
            })

    # 去重：同一个 key 只保留第一条（附带来源最多的优先）
    uniq: dict[str, dict] = {}
    for item in results:
        uniq.setdefault(item["authKey"], item)

    if args.json:
        print(json.dumps(list(uniq.values()), ensure_ascii=False, indent=2))
        return 0 if uniq else 1

    if not uniq:
        print("没有找到 AuthKey。")
        print("检查清单：")
        print("  1. 是否已在小米运动健康里完成「设备数据同步成功」后再导出日志")
        print("  2. 导出的是「迁移日志」而不是崩溃日志")
        print("  3. 手环是否仍绑定在该账号下（删过设备就要重新配对）")
        return 1

    print(f"找到 {len(uniq)} 个 AuthKey：\n")
    for i, item in enumerate(uniq.values(), 1):
        device = item["device"] or "未知设备"
        print(f"[{i}] {item['authKey']}")
        print(f"    设备   : {device}")
        print(f"    来源   : {item['source']}")
        print(f"    上下文 : {item['context'][:100]}")
        print()
    if len(uniq) > 1:
        print("提示：一台手环对应一个 Key。按上面的设备名挑出你的手环 10 NFC 版对应的那一个。")
    print("把这串 32 位字符粘到 BandBox → 设置 → 设备凭证。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
