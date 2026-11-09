#!/usr/bin/env python3
"""vbs_text.py — encoding detection and safe write-back for VBS/log text

Uses the same detection rules as TextEncoding.psm1:
  1) If a BOM is present, trust it (UTF-8-BOM / UTF-16LE / UTF-16BE)
  2) BOM-less UTF-16LE: in ASCII text every other byte is 0x00, which identifies it
  3) No BOM and strict UTF-8 decoding succeeds → UTF-8; otherwise → ANSI (the Windows code page, 936 for Chinese)

Writes go to a temporary file in the same directory first and are then replaced atomically, so an interrupted
process cannot corrupt the .vbs file; when the search string is absent, nothing is written at all.

Usage:
  python vbs_text.py probe <files...>
  python vbs_text.py replace <file> --old A --new B [--all]
"""

import argparse
import ctypes
import json
import os
import sys
import time
from pathlib import Path


def ansi_codec() -> str:
    """Python codec name for the machine's ANSI code page (cp936 on Chinese Windows)."""
    try:
        acp = ctypes.windll.kernel32.GetACP()
        if acp:
            return "cp%d" % acp
    except Exception:
        pass
    return "mbcs"


def detect_encoding(data: bytes) -> dict:
    """Detect the encoding and return kind / codec / bom."""
    if data.startswith(b"\xef\xbb\xbf"):
        return {"kind": "utf-8-bom", "codec": "utf-8-sig", "bom": True}
    if data.startswith(b"\xff\xfe"):
        return {"kind": "utf-16le", "codec": "utf-16-le", "bom": True}
    if data.startswith(b"\xfe\xff"):
        return {"kind": "utf-16be", "codec": "utf-16-be", "bom": True}

    # BOM-less UTF-16LE: most odd-positioned bytes are 0x00
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
    """Decode according to the detection result (UTF-16 with a BOM is left to the codec, which infers byte order)."""
    if info["kind"] == "utf-8-bom":
        return data.decode("utf-8-sig")
    if info["bom"]:
        return data.decode("utf-16")
    return data.decode(info["codec"])


def encode_text(text: str, info: dict) -> bytes:
    """Encode according to the detection result; the BOM is added explicitly here so the file keeps the same encoding."""
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
    """Read a file with automatic encoding detection; returns (text, encoding info)."""
    data = Path(path).read_bytes()
    info = detect_encoding(data)
    return decode_bytes(data, info), info


def write_text(path, text: str, info: dict = None) -> dict:
    """Write the text back in its original encoding, safely (temporary file + atomic replace)."""
    p = Path(path)
    if info is None:
        info = detect_encoding(p.read_bytes() if p.exists() else b"")
    data = encode_text(text, info)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_bytes(data)
    # On Windows the target file may be briefly locked by Defender, Excel or another process;
    # os.replace then raises WinError 5, so retry a few times before giving up.
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
    """Replace text and write it back in the original encoding; returns (replacements, encoding info). Nothing is written when there is no match."""
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
    ap = argparse.ArgumentParser(description="Detect the encoding of VBS/log text and write it back safely")
    sub = ap.add_subparsers(dest="cmd")
    p_probe = sub.add_parser("probe", help="print the detected encoding of each file")
    p_probe.add_argument("files", nargs="+")
    p_rep = sub.add_parser("replace", help="replace text and write it back in the original encoding")
    p_rep.add_argument("file")
    p_rep.add_argument("--old", required=True)
    p_rep.add_argument("--new", required=True)
    p_rep.add_argument("--all", action="store_true", help="replace every match (only the first is replaced by default)")
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
