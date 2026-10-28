#!/usr/bin/env python3
"""vbs_text.py — VBS/日志文本的编码探测与安全写回

与 TextEncoding.psm1 使用同一套判定规则：
  1) 有 BOM 时以 BOM 为准（UTF-8-BOM / UTF-16LE / UTF-16BE）
  2) 无 BOM 的 UTF-16LE：ASCII 文本每隔一个字节就是 0x00，据此识别
  3) 无 BOM 且能严格按 UTF-8 解码 → UTF-8；否则 → ANSI（Windows 代码页，中文为 936）

写回先落到同目录临时文件再原子替换，避免进程中断把 .vbs 写坏；
未命中替换串时直接返回，不写文件。

用法：
  python vbs_text.py probe <文件...>
  python vbs_text.py replace <文件> --old A --new B [--all]
"""

import argparse
import ctypes
import json
import os
import sys
import time
from pathlib import Path


def ansi_codec() -> str:
    """本机 ANSI 代码页对应的 Python 编码名（中文 Windows 为 cp936）。"""
    try:
        acp = ctypes.windll.kernel32.GetACP()
        if acp:
            return "cp%d" % acp
    except Exception:
        pass
    return "mbcs"


def detect_encoding(data: bytes) -> dict:
    """探测编码，返回 kind / codec / bom 三项。"""
    if data.startswith(b"\xef\xbb\xbf"):
        return {"kind": "utf-8-bom", "codec": "utf-8-sig", "bom": True}
    if data.startswith(b"\xff\xfe"):
        return {"kind": "utf-16le", "codec": "utf-16-le", "bom": True}
    if data.startswith(b"\xfe\xff"):
        return {"kind": "utf-16be", "codec": "utf-16-be", "bom": True}

    # 无 BOM 的 UTF-16LE：奇数位大量 0x00
    if len(data) >= 4:
        zeros = sum(1 for i in range(1, len(data), 2) if data[i] == 0)
        if zeros >= int((len(data) // 2) * 0.6):
            return {"kind": "utf-16le", "codec": "utf-16-le", "bom": False}

    try:
        data.decode("utf-8", errors="strict")
        return {"kind": "utf-8", "codec": "utf-8", "bom": False}
    except UnicodeDecodeError:
        return {"kind": "ansi", "codec": ansi_codec(), "bom": False}


def decode_bytes(data: bytes, info: dict) -> str:
    """按探测结果解码（带 BOM 的 UTF-16 交给 codec 自动识别字节序）。"""
    if info["kind"] == "utf-8-bom":
        return data.decode("utf-8-sig")
    if info["bom"]:
        return data.decode("utf-16")
    return data.decode(info["codec"])


def encode_text(text: str, info: dict) -> bytes:
    """按探测结果编码，BOM 由这里显式补上，保证写回后仍是同一编码。"""
    kind = info["kind"]
    if kind == "utf-8-bom":
        return text.encode("utf-8-sig")
    if kind == "utf-16be":
        return (b"\xfe\xff" if info["bom"] else b"") + text.encode("utf-16-be")
    if kind == "utf-16le":
        return (b"\xff\xfe" if info["bom"] else b"") + text.encode("utf-16-le")
    if kind == "ansi":
        return text.encode(ansi_codec())
    return text.encode("utf-8")


def read_text(path) -> tuple:
    """自动识别编码读取，返回 (文本, 编码信息)。"""
    data = Path(path).read_bytes()
    info = detect_encoding(data)
    return decode_bytes(data, info), info


def write_text(path, text: str, info: dict = None) -> dict:
    """保留原编码安全写回（临时文件 + 原子替换）。"""
    p = Path(path)
    if info is None:
        info = detect_encoding(p.read_bytes() if p.exists() else b"")
    data = encode_text(text, info)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_bytes(data)
    # Windows 上目标文件可能被 Defender 或 Excel 等进程短暂占用，
    # 此时 os.replace 会抛 WinError 5，重试几次再放弃
    for attempt in range(6):
        try:
            os.replace(str(tmp), str(p))
            return info
        except PermissionError:
            if attempt == 5:
                tmp.unlink(missing_ok=True)
                raise
            time.sleep(0.1)
    return info


def replace_text(path, old: str, new: str, count: int = 1) -> tuple:
    """替换文本并保留编码写回；返回 (替换次数, 编码信息)。未命中不写文件。"""
    text, info = read_text(path)
    n = text.count(old)
    if n == 0:
        return 0, info
    if count < 0:
        text = text.replace(old, new)
        done = n
    else:
        text = text.replace(old, new, count)
        done = min(n, count)
    write_text(path, text, info)
    return done, info


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="VBS/日志文本编码探测与安全写回")
    sub = ap.add_subparsers(dest="cmd")
    p_probe = sub.add_parser("probe", help="打印文件的编码判定结果")
    p_probe.add_argument("files", nargs="+")
    p_rep = sub.add_parser("replace", help="替换文本并按原编码写回")
    p_rep.add_argument("file")
    p_rep.add_argument("--old", required=True)
    p_rep.add_argument("--new", required=True)
    p_rep.add_argument("--all", action="store_true", help="替换全部命中（默认只替换第一处）")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 1

    if args.cmd == "probe":
        for f in args.files:
            info = detect_encoding(Path(f).read_bytes())
            print(json.dumps({"file": f, "kind": info["kind"], "bom": info["bom"]}, ensure_ascii=False))
        return 0

    done, info = replace_text(args.file, args.old, args.new, -1 if args.all else 1)
    print(json.dumps({"file": args.file, "kind": info["kind"], "bom": info["bom"], "replaced": done},
                     ensure_ascii=False))
    return 0 if done else 2


if __name__ == "__main__":
    sys.exit(main())
