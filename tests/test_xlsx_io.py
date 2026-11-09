# -*- coding: utf-8 -*-
"""Tests for the read-only Excel layer: header lookup / date and number conversion /
whole-sheet reading / rule tables / header inspection

Covers both the legacy contract and the newer semantics:
  1. headers are located by name (exact match first, prefix fallback, None when absent);
  2. date conversion keeps the existing formats and the Excel serial-number convention,
     and returns None when parsing fails;
  3. number conversion separates "empty" from "invalid", while the legacy to_number
     still returns None for both;
  4. reading a rule sheet into a dict is a pure function: an empty sheet returns {}, a
     missing key column raises, and duplicate keys raise;
  5. --dump is a read-only diagnostic entry point: it prints column names and inferred
     types without touching the file.
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


# ── Header lookup ─────────────────────────────────────────────
def test_find_col_exact_case_and_space_insensitive():
    """Header matching ignores case and surrounding spaces, and tries exact hits in the order of names first"""
    hdr = [" 物料号 ", "PO 号", "数量"]
    assert xlsx_io.find_col(hdr, ["物料号"]) == 1
    assert xlsx_io.find_col(hdr, ["po 号"]) == 2
    assert xlsx_io.find_col(hdr, ["数量"]) == 3


def test_find_col_prefers_first_exact_then_prefix():
    """Exact matches are tried in the order of names; the prefix fallback only applies when none hits"""
    hdr = ["净重（kg）", "净重", "数量"]
    assert xlsx_io.find_col(hdr, ["净重"]) == 2, "精确命中应优先于前缀命中"
    assert xlsx_io.find_col(hdr, ["毛重"], prefix="净重") == 1, "没有精确命中时按前缀兜底"


def test_find_col_missing_returns_none():
    """A missing column name returns None, leaving it to the caller to fail hard or tolerate the absence"""
    assert xlsx_io.find_col(["物料号", "数量"], ["批号"]) is None
    assert xlsx_io.find_col(["物料号", "数量"], ["批号"], prefix="批") is None


# ── Date conversion ───────────────────────────────────────────
@pytest.mark.parametrize("text", [
    "2026-10-26", "2026/10/26", "2026.10.26", "26.10.2026", "26/10/2026", "20261026",
])
def test_to_date_supports_legacy_string_formats(text):
    """All six legacy string formats must stay parseable"""
    assert xlsx_io.to_date(text) == date(2026, 10, 26)


def test_to_date_supports_datetime_date_and_serial():
    """The datetime, date and Excel serial-number paths must agree"""
    assert xlsx_io.to_date(datetime(2026, 10, 26, 15, 30)) == date(2026, 10, 26)
    assert xlsx_io.to_date(date(2026, 10, 26)) == date(2026, 10, 26)
    # Excel serial numbers start at 1899-12-30, so serial 1 is 1899-12-31
    assert xlsx_io.to_date(1) == date(1899, 12, 31)


def test_to_date_invalid_returns_none():
    """Parse failures and empty values both return None: the caller treats them as "unparseable"
    and never guesses a date"""
    assert xlsx_io.to_date(None) is None
    assert xlsx_io.to_date("不是日期") is None
    assert xlsx_io.to_date("") is None


# ── Number conversion ─────────────────────────────────────────
def test_parse_number_distinguishes_empty_and_invalid():
    """Empty values and blank strings classify as empty; text that does not parse as a number is
    invalid; the two must never be conflated"""
    assert xlsx_io.parse_number(None) == (None, "empty")
    assert xlsx_io.parse_number("") == (None, "empty")
    assert xlsx_io.parse_number("   ") == (None, "empty")
    assert xlsx_io.parse_number("abc") == (None, "invalid")
    assert xlsx_io.parse_number("12abc") == (None, "invalid")


def test_parse_number_strips_thousands_separator():
    """Text with thousands separators has the commas stripped first, matching the legacy behaviour"""
    assert xlsx_io.parse_number("1,234.5") == (1234.5, "number")
    assert xlsx_io.parse_number(7) == (7.0, "number")


def test_to_number_keeps_legacy_none_semantics():
    """Legacy contract: empty and invalid values both return None, so existing callers see unchanged output"""
    assert xlsx_io.to_number(None) is None
    assert xlsx_io.to_number("") is None
    assert xlsx_io.to_number("abc") is None
    assert xlsx_io.to_number("1,234.5") == 1234.5


def test_infer_column_type_by_stored_type():
    """Column type is inferred from how the cells are stored: date / number / text / empty / mixed"""
    assert xlsx_io.infer_column_type([datetime(2026, 10, 26), None]) == "date"
    assert xlsx_io.infer_column_type([1, 2.5]) == "number"
    assert xlsx_io.infer_column_type(["甲", "乙"]) == "text"
    assert xlsx_io.infer_column_type([None, ""]) == "empty"
    assert xlsx_io.infer_column_type([1, "甲"]) == "mixed"


# ── Whole-sheet reading ───────────────────────────────────────
def test_load_grid_and_header_row(tmp_path):
    """Whole-sheet reading keeps formula source text (read-only mode), and header_row_grid extracts the header"""
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
    """Only max_col columns are read, so tens of thousands of leftover formatted empty columns do not eat memory"""
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


# ── Rule sheet -> dict (pure function) ────────────────────────
def _rule_sheet(rows):
    """Build a sheet with the key / value / unit / note columns"""
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值", "单位", "说明"])
    for r in rows:
        ws.append(list(r))
    return wb, ws


def test_read_rule_table_returns_dict():
    """A normal sheet reads as {key: {value, unit, note}} and keeps the raw cell values"""
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
    """A sheet with nothing but a header returns {}, without raising"""
    wb, ws = _rule_sheet([])
    assert xlsx_io.read_rule_table(ws) == {}
    wb.close()


def test_read_rule_table_blank_workbook_returns_empty_dict():
    """A completely blank worksheet also returns {}"""
    wb = Workbook()
    ws = wb.active
    assert xlsx_io.read_rule_table(ws) == {}
    wb.close()


def test_read_rule_table_missing_key_column_raises():
    """A missing key column raises instead of silently yielding an empty dict: column drift must be noticed"""
    wb = Workbook()
    ws = wb.active
    ws.append(["名称", "值", "单位"])
    ws.append(["阈值", 0.95, "%"])
    with pytest.raises(ValueError, match="项目"):
        xlsx_io.read_rule_table(ws)
    wb.close()


def test_read_rule_table_duplicate_key_raises():
    """Duplicate keys are ambiguous, so raise rather than silently keep the last row"""
    wb, ws = _rule_sheet([("阈值", 1), ("阈值", 2)])
    with pytest.raises(ValueError, match="重复"):
        xlsx_io.read_rule_table(ws)
    wb.close()


def test_read_rule_table_optional_columns_absent():
    """When the unit / note columns are absent their fields are None, which does not affect the value lookup"""
    wb = Workbook()
    ws = wb.active
    ws.append(["项目", "值"])
    ws.append(["阈值", 3])
    rules = xlsx_io.read_rule_table(ws)
    assert rules == {"阈值": {"value": 3, "unit": None, "note": None}}
    wb.close()


# ── Header inspection CLI ─────────────────────────────────────
def _dump(path, *extra):
    return subprocess.run(
        [sys.executable, str(MODULE), "--dump", str(path), *extra],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)


def test_dump_prints_columns_and_types(tmp_path):
    """--dump prints each worksheet's column names and inferred types"""
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
    assert "[sheet] 规则" in out
    assert "column 1: 项目 (text)" in out
    assert "column 2: 值 (number)" in out
    assert "column 3: 日期 (date)" in out
    assert "[sheet] 空表" in out
    assert "(empty sheet or no header)" in out


def test_dump_is_read_only(tmp_path):
    """--dump must not change a single byte of the file"""
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
    """Missing file: exit code 1 and the error goes to stderr"""
    proc = _dump(tmp_path / "nope.xlsx")
    assert proc.returncode == 1
    assert "workbook not found" in proc.stderr
