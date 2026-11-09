# vbs_text 编码探测与安全写回测试（pytest）
#
# 与 tests/TextEncoding.Tests.ps1 覆盖同一组编码来源：
# UTF-8-BOM / ANSI（本机代码页）/ UTF-16LE（VBS 日志），
# 断言读出的内容正确、写回后字节级编码不变。

import sys
from pathlib import Path

import pytest

# 被测脚本在 tools/pad-sync 下，直接把该目录加入导入路径
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "pad-sync"))

import vbs_text  # noqa: E402

# ANSI 场景只对「本机代码页能表示中文」的系统有意义（中文 Windows 的 cp936）；
# 英文 Windows 的 cp1252 编不出中文，这两个用例在那种环境下跳过
_ANSI_CAN_ENCODE_CJK = True
try:
    "中文".encode(vbs_text.ansi_codec())
except UnicodeEncodeError:
    _ANSI_CAN_ENCODE_CJK = False

needs_cjk_ansi = pytest.mark.skipif(
    not _ANSI_CAN_ENCODE_CJK,
    reason="本机 ANSI 代码页无法表示中文，ANSI 中文场景不适用",
)


def test_utf8_bom_probe_and_roundtrip(tmp_path):
    p = tmp_path / "a.vbs"
    p.write_bytes(b"\xef\xbb\xbf" + "中文注释\r\nWScript.Echo 1".encode("utf-8"))

    text, info = vbs_text.read_text(p)
    assert info["kind"] == "utf-8-bom"
    assert info["bom"] is True
    assert "中文注释" in text

    vbs_text.write_text(p, text + "\r\n追加", info)
    raw = p.read_bytes()
    assert raw.startswith(b"\xef\xbb\xbf")
    assert "追加" in vbs_text.read_text(p)[0]


@needs_cjk_ansi
def test_ansi_probe_and_roundtrip(tmp_path):
    p = tmp_path / "b.log"
    raw = "导出失败：找不到窗口".encode(vbs_text.ansi_codec())
    p.write_bytes(raw)

    text, info = vbs_text.read_text(p)
    assert info["kind"] == "ansi"
    assert text == "导出失败：找不到窗口"

    vbs_text.write_text(p, text, info)
    assert p.read_bytes() == raw


def test_utf16le_probe_and_roundtrip(tmp_path):
    p = tmp_path / "c.log"
    p.write_bytes(b"\xff\xfe" + "过账完成 2 行".encode("utf-16-le"))

    text, info = vbs_text.read_text(p)
    assert info["kind"] == "utf-16le"
    assert info["bom"] is True
    assert text == "过账完成 2 行"

    vbs_text.write_text(p, text + "!", info)
    raw = p.read_bytes()
    assert raw[:2] == b"\xff\xfe"
    assert vbs_text.read_text(p)[0] == "过账完成 2 行!"


def test_utf8_without_bom_not_misjudged_as_ansi(tmp_path):
    p = tmp_path / "d.txt"
    p.write_bytes("中文内容".encode("utf-8"))

    text, info = vbs_text.read_text(p)
    assert info["kind"] == "utf-8"
    assert info["bom"] is False
    assert text == "中文内容"


@needs_cjk_ansi
def test_replace_keeps_original_encoding(tmp_path):
    # 模拟把 VBS 里硬编码的路径替换成新值，写回后仍是 ANSI
    # 内容必须带中文：纯 ASCII 的 ANSI 字节同时也是合法 UTF-8，按编码字节无法区分
    p = tmp_path / "e.vbs"
    old_line = 'Const ROOT = "C:\\PAD\\Scripts"  \' 根目录'
    new_line = 'Const ROOT = "C:\\Temp\\PAD\\Scripts"  \' 根目录'
    raw = old_line.encode(vbs_text.ansi_codec())
    p.write_bytes(raw)

    done, info = vbs_text.replace_text(p, 'C:\\PAD\\Scripts', 'C:\\Temp\\PAD\\Scripts')
    assert done == 1
    assert info["kind"] == "ansi"
    assert p.read_bytes() == new_line.encode(vbs_text.ansi_codec())
    # 未命中时不写文件
    done2, _ = vbs_text.replace_text(p, "不存在的片段", "x")
    assert done2 == 0
    assert p.read_bytes() == new_line.encode(vbs_text.ansi_codec())
