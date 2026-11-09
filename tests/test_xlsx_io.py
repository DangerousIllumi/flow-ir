# -*- coding: utf-8 -*-
"""Excel 只读读取层测试：表头定位 / 日期与数值转换 / 整表读取 / 规则表 / 表头探查

重点覆盖历史口径与新增语义：
  1. 表头按名称定位（精确优先、前缀兜底、缺列返回 None）；
  2. 日期转换保持既有格式与 Excel 序列号口径，解析失败返回 None；
  3. 数值转换区分「空」与「非法」，旧口径 to_number 仍统一返回 None；
  4. 规则页签读成字典是纯函数：空表返回 {}、缺列报错、重复键报错；
  5. --dump 只读排障入口：打印列名与推断类型，且不改动文件。
"""
import hashlib
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

import pytest
from openpyxl import Workbook, load_workbook

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "xlsx"))

import xlsx_io  # noqa: E402

MODULE = ROOT / "tools" / "xlsx" / "xlsx_io.py"


# ── 表头定位 ──────────────────────────────────────────────────
def test_find_col_exact_case_and_space_insensitive():
    """表头匹配忽略大小写与首尾空格，并按 names 的顺序优先精确命中"""
    hdr = [" 物料号 ", "PO 号", "数量"]
    assert xlsx_io.find_col(hdr, ["物料号"]) == 1
    assert xlsx_io.find_col(hdr, ["po 号"]) == 2
    assert xlsx_io.find_col(hdr, ["数量"]) == 3


def test_find_col_prefers_first_exact_then_prefix():
    """先按 names 顺序精确匹配，全部不中才用前缀兜底"""
    hdr = ["净重（kg）", "净重", "数量"]
    assert xlsx_io.find_col(hdr, ["净重"]) == 2, "精确命中应优先于前缀命中"
    assert xlsx_io.find_col(hdr, ["毛重"], prefix="净重") == 1, "没有精确命中时按前缀兜底"


def test_find_col_missing_returns_none():
    """列名缺失返回 None，由调用方决定硬失败还是可缺省"""
    assert xlsx_io.find_col(["物料号", "数量"], ["批号"]) is None
    assert xlsx_io.find_col(["物料号", "数量"], ["批号"], prefix="批") is None


# ── 日期转换 ──────────────────────────────────────────────────
@pytest.mark.parametrize("text", [
    "2026-10-26", "2026/10/26", "2026.10.26", "26.10.2026", "26/10/2026", "20261026",
])
def test_to_date_supports_legacy_string_formats(text):
    """六种历史字符串格式都必须继续可解析"""
    assert xlsx_io.to_date(text) == date(2026, 10, 26)


def test_to_date_supports_datetime_date_and_serial():
    """datetime / date / Excel 序列号三条路径保持一致"""
    assert xlsx_io.to_date(datetime(2026, 10, 26, 15, 30)) == date(2026, 10, 26)
    assert xlsx_io.to_date(date(2026, 10, 26)) == date(2026, 10, 26)
    # Excel 序列号原点 1899-12-30：序列号 1 即 1899-12-31
    assert xlsx_io.to_date(1) == date(1899, 12, 31)


def test_to_date_invalid_returns_none():
    """解析失败与空值都返回 None（调用方按「无法解析」处理，绝不猜日期）"""
    assert xlsx_io.to_date(None) is None
    assert xlsx_io.to_date("不是日期") is None
    assert xlsx_io.to_date("") is None


# ── 数值转换 ──────────────────────────────────────────────────
def test_parse_number_distinguishes_empty_and_invalid():
    """空值、空白字符串是 empty；解析不成数值是 invalid；两者不得混为一谈"""
    assert xlsx_io.parse_number(None) == (None, "empty")
    assert xlsx_io.parse_number("") == (None, "empty")
    assert xlsx_io.parse_number("   ") == (None, "empty")
    assert xlsx_io.parse_number("abc") == (None, "invalid")
    assert xlsx_io.parse_number("12abc") == (None, "invalid")


def test_parse_number_strips_thousands_separator():
    """带千分位的文本按历史口径去掉逗号后再解析"""
    assert xlsx_io.parse_number("1,234.5") == (1234.5, "number")
    assert xlsx_io.parse_number(7) == (7.0, "number")


def test_to_number_keeps_legacy_none_semantics():
    """旧口径：空值与非法值都返回 None，现有调用方输出不变"""
    assert xlsx_io.to_number(None) is None
    assert xlsx_io.to_number("") is None
    assert xlsx_io.to_number("abc") is None
    assert xlsx_io.to_number("1,234.5") == 1234.5


def test_infer_column_type_by_stored_type():
    """列类型按单元格存储类型推断：日期 / 数值 / 文本 / 空 / 混合"""
    assert xlsx_io.infer_column_type([datetime(2026, 10, 26), None]) == "日期"
    assert xlsx_io.infer_column_type([1, 2.5]) == "数值"
    assert xlsx_io.infer_column_type(["甲", "乙"]) == "文本"
    assert xlsx_io.infer_column_type([None, ""]) == "空"
    assert xlsx_io.infer_column_type([1, "甲"]) == "混合"


# ── 整表读取 ──────────────────────────────────────────────────
def test_load_grid_and_header_row(tmp_path):
    """整表读取保留公式原文（只读模式），并可用 header_row_grid 取表头"""
    path = tmp_path / "table.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值"])
    ws.append(["甲", "=B2*2"])
    wb.save(str(path))
    wb.close()

    ro = load_workbook(str(path), read_only=True, data_only=False)
    try:
        grid = xlsx_io.load_grid(ro[ro.sheetnames[0]], max_col=3)
    finally:
        ro.close()
    assert xlsx_io.header_row_grid(grid) == ["项目", "值", None]
    assert grid[1][1] == "=B2*2", "只读读取不得提前求值，公式原文保留"


def test_load_grid_caps_columns(tmp_path):
    """只读到 max_col 列，避免格式残留的上万空列占内存"""
    path = tmp_path / "wide.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.append(list(range(1, 81)))
    wb.save(str(path))
    wb.close()
    ro = load_workbook(str(path), read_only=True, data_only=True)
    try:
        grid = xlsx_io.load_grid(ro[ro.sheetnames[0]], max_col=10)
    finally:
        ro.close()
    assert len(grid[0]) == 10


# ── 规则页签 → 字典（纯函数）────────────────────────────────
def _rule_sheet(rows):
    """造一张「项目 / 值 / 单位 / 说明」页签"""
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值", "单位", "说明"])
    for r in rows:
        ws.append(list(r))
    return wb, ws


def test_read_rule_table_returns_dict():
    """正常页签读成 {项目: {value, unit, note}}，保留原始单元格值"""
    wb, ws = _rule_sheet([
        ("阈值", 0.95, "%", "超过该值才算命中"),
        ("上限", "100", "件", ""),
    ])
    rules = xlsx_io.read_rule_table(ws)
    assert rules == {
        "阈值": {"value": 0.95, "unit": "%", "note": "超过该值才算命中"},
        "上限": {"value": "100", "unit": "件", "note": ""},
    }
    wb.close()


def test_read_rule_table_empty_sheet_returns_empty_dict():
    """空表（只有表头）返回 {}，不报错"""
    wb, ws = _rule_sheet([])
    assert xlsx_io.read_rule_table(ws) == {}
    wb.close()


def test_read_rule_table_blank_workbook_returns_empty_dict():
    """工作表完全空白时同样返回 {}"""
    wb = Workbook()
    ws = wb.active
    assert xlsx_io.read_rule_table(ws) == {}
    wb.close()


def test_read_rule_table_missing_key_column_raises():
    """列名缺失直接报错，不能静默读成空字典（列漂移必须被人看到）"""
    wb = Workbook()
    ws = wb.active
    ws.append(["名称", "值", "单位"])
    ws.append(["阈值", 0.95, "%"])
    with pytest.raises(ValueError, match="项目"):
        xlsx_io.read_rule_table(ws)
    wb.close()


def test_read_rule_table_duplicate_key_raises():
    """项目值重复属于歧义，直接报错而不是静默取最后一行"""
    wb, ws = _rule_sheet([("阈值", 1), ("阈值", 2)])
    with pytest.raises(ValueError, match="重复"):
        xlsx_io.read_rule_table(ws)
    wb.close()


def test_read_rule_table_optional_columns_absent():
    """单位 / 说明列不存在时对应字段记 None，不影响取值"""
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值"])
    ws.append(["阈值", 3])
    rules = xlsx_io.read_rule_table(ws)
    assert rules == {"阈值": {"value": 3, "unit": None, "note": None}}
    wb.close()


# ── 表头探查 CLI ─────────────────────────────────────────────
def _dump(path, *extra):
    return subprocess.run(
        [sys.executable, str(MODULE), "--dump", str(path), *extra],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)


def test_dump_prints_columns_and_types(tmp_path):
    """--dump 打印每张工作表的列名与推断类型"""
    path = tmp_path / "dump.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.title = "规则"
    ws.append(["项目", "值", "日期"])
    ws.append(["甲", 1, datetime(2026, 10, 26)])
    ws.append(["乙", 2, datetime(2026, 10, 27)])
    wb.create_sheet("空表")
    wb.save(str(path))
    wb.close()

    proc = _dump(path)
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "[工作表] 规则" in out
    assert "列1：项目（文本）" in out
    assert "列2：值（数值）" in out
    assert "列3：日期（日期）" in out
    assert "[工作表] 空表" in out
    assert "（空表或无表头）" in out


def test_dump_is_read_only(tmp_path):
    """--dump 不得改动文件字节"""
    path = tmp_path / "readonly.xlsx"
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值"])
    ws.append(["甲", 1])
    wb.save(str(path))
    wb.close()
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    assert _dump(path).returncode == 0
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before


def test_dump_missing_file_fails(tmp_path):
    """文件不存在：退出码 1，错误写 stderr"""
    proc = _dump(tmp_path / "nope.xlsx")
    assert proc.returncode == 1
    assert "工作簿不存在" in proc.stderr
