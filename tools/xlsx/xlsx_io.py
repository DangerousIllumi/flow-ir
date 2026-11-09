# -*- coding: utf-8 -*-
"""xlsx_io.py — read-only Excel access layer (generic; contains no business rules)

Every script in this repository that reads an xlsx shares this one implementation, so the conventions cannot drift apart.
This module only reads: it never writes a cell, never modifies a file, and keeps no module-level mutable state.

Public functions:
  norm(v)                        cell value -> string for header matching (trimmed + lower-cased)
  find_col(header, names, prefix=None)
                                 locate a column number (1-based) by header name: exact match first, prefix as fallback
  to_date(v)                     lenient date conversion (datetime / date / Excel serial number / common strings)
  parse_number(v)                lenient number conversion, returns (value, status)
                                 status number=parsed / empty=blank / invalid=unparsable
  to_number(v)                   legacy number conversion: blank and invalid both return None (keeps existing callers working)
  load_grid(ws, max_col=60)      worksheet -> 2-D list (streamed read-only read)
  header_row_grid(grid)          the header row of a 2-D list
  read_rule_table(ws, ...)       rule sheet -> dict (pure function, writes no module-level global)
  infer_column_type(values)      infer a column type from how cells are stored (used by the header inspector)

CLI (read-only troubleshooting for template swaps / column drift):
  python xlsx_io.py --dump <workbook> [--sheet <name>] [--max-col N]
      print every worksheet's column names and inferred types without modifying the file.
"""
import argparse
import os
import sys
from datetime import date, datetime, timedelta

from openpyxl import load_workbook

# The three number states: empty (nothing filled in) and invalid (filled in but unparsable) must stay distinct;
# collapsing both into 0 would disguise dirty data as a legitimate number and hide the upstream problem.
NUMBER = "number"
EMPTY = "empty"
INVALID = "invalid"

# Common date string layouts (kept in line with existing callers; no new formats, so existing decisions do not change)
DATE_FORMATS = ("%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d", "%d.%m.%Y", "%d/%m/%Y", "%Y%m%d")


def norm(v):
    """Normalise any cell value into a string for header matching (trimmed + lower-cased)"""
    return str(v).strip().lower() if v is not None else ""


def find_col(header, names, prefix=None):
    """Find a column number (1-based) by name in the header row. `names` are exact matches, `prefix` is the fallback.

    Try each name in order as an exact match first, and fall back to the prefix only when none of them match;
    returning None means the header has no such column (the caller decides whether that is fatal or optional).
    """
    for want in names:
        w = norm(want)
        for i, v in enumerate(header):
            if norm(v) == w:
                return i + 1
    if prefix:
        p = norm(prefix)
        for i, v in enumerate(header):
            if norm(v).startswith(p):
                return i + 1
    return None


def to_date(v):
    """Convert a cell value to a date: supports datetime / date / Excel serial number / common string dates

    Return None when it cannot be parsed (keeps the historical convention: callers treat None as "unparsable"
    and skip that filter, so it must not be reinterpreted as some default date here).
    """
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    if isinstance(v, (int, float)):
        # Excel serial number: the epoch is 1899-12-30
        try:
            return (datetime(1899, 12, 30) + timedelta(days=float(v))).date()
        except Exception:
            return None
    s = str(v).strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).date()
        except Exception:
            continue
    return None


def parse_number(v):
    """Turn a cell value into (number, status)

    Status:
      number  — parsed successfully; the first item is a float
      empty   — empty cell / blank string; the first item is None
      invalid — something was filled in but it is not a number; the first item is None

    Keeping empty and invalid apart is a hard requirement of this layer: dirty data must never quietly become 0 or blank.
    """
    if v is None:
        return None, EMPTY
    if isinstance(v, str) and not v.strip():
        return None, EMPTY
    if isinstance(v, (int, float)):
        # bool is a subclass of int; the existing implementation treats it as 1/0, so keep that behaviour
        return float(v), NUMBER
    try:
        return float(str(v).strip().replace(",", "")), NUMBER
    except Exception:
        return None, INVALID


def to_number(v):
    """Legacy number conversion: both an unparsable value and a blank one return None

    Kept only so existing callers keep their behaviour; new code that must tell "blank" from "invalid" uses parse_number.
    """
    return parse_number(v)[0]


def load_grid(ws, max_col=60):
    """Read a worksheet into a 2-D list (0-based indices)

    Only the first max_col columns are read on purpose: format leftovers in real reports push max_column into the tens of thousands,
    and reading it all would load empty columns as well. Headers and business columns sit far inside that range.
    Traverse the sheet once (with read_only, every iter_rows call re-parses the whole sheet, so two passes cost double).
    """
    grid = []
    for row in ws.iter_rows(min_col=1, max_col=max_col, values_only=True):
        grid.append(list(row))
    return grid


def header_row_grid(grid):
    """The header row (row 0 of the 2-D list); an empty sheet returns an empty list"""
    return list(grid[0]) if grid else []


def _trim_trailing_empty(header):
    """Drop trailing empty columns from the header, so dozens of meaningless "empty column" labels are not printed"""
    i = len(header)
    while i > 0 and norm(header[i - 1]) == "":
        i -= 1
    return header[:i]


def infer_column_type(values, sample=20):
    """Infer a column type from how its cells are stored (only the first `sample` non-empty values are sampled)

    The rule looks solely at how the cell is stored in the file and never parses a string back into a date:
      date/datetime -> date; int/float -> number; anything else -> text;
      more than one non-empty kind -> mixed; nothing but blanks -> empty.
    """
    kinds = set()
    for v in list(values)[:sample]:
        if v is None:
            continue
        if isinstance(v, date):
            kinds.add("date")
        elif isinstance(v, (int, float)):
            kinds.add("number")
        else:
            s = str(v).strip()
            if not s:
                continue
            kinds.add("text")
    if not kinds:
        return "empty"
    if len(kinds) == 1:
        return kinds.pop()
    return "mixed"


def read_rule_table(ws, key_header="项目", value_header="值", unit_header="单位",
                    note_header="说明", header_row=0, max_col=60):
    """Read an "item / value / unit / note" style sheet into a rule dict (pure function)

    Returns {item: {"value": value, "unit": unit, "note": note}};
    all three fields keep the raw cell value, with no number conversion (a rule value may be a percentage, a code, ...).

    Conventions:
      - the header row defaults to row 1 (index 0); an empty sheet returns {};
      - missing "item" or "value" columns raise an error: column drift must not silently become an empty dict;
      - "unit" and "note" are optional; the field is None when its column is missing;
      - a duplicate item value raises an error (ambiguity fails; the last row is never silently taken).
    """
    grid = load_grid(ws, max_col=max_col)
    if header_row >= len(grid):
        return {}
    hdr = grid[header_row]
    # An all-empty header row means a blank sheet: return an empty dict instead of reporting a missing column
    if all(norm(h) == "" for h in hdr):
        return {}
    c_key = find_col(hdr, [key_header])
    c_val = find_col(hdr, [value_header])
    if not c_key or not c_val:
        missing = [n for n, c in ((key_header, c_key), (value_header, c_val)) if not c]
        raise ValueError("规则页签缺少必需列：%s" % "、".join(missing))
    c_unit = find_col(hdr, [unit_header]) if unit_header else None
    c_note = find_col(hdr, [note_header]) if note_header else None

    def cell(row, col):
        if not col or col > len(row):
            return None
        return row[col - 1]

    rules = {}
    rows_of_key = {}
    for r in range(header_row + 1, len(grid)):
        row = grid[r]
        k = cell(row, c_key)
        if norm(k) == "":
            continue
        key = str(k).strip()
        if key in rules:
            raise ValueError("规则页签的项目值重复：%s（第 %d、%d 行）"
                             % (key, rows_of_key[key] + 1, r + 1))
        rows_of_key[key] = r
        rules[key] = {
            "value": cell(row, c_val),
            "unit": cell(row, c_unit),
            "note": cell(row, c_note),
        }
    return rules


def dump_workbook(path, sheet=None, max_col=60):
    """Print a workbook's column names and inferred types, read-only (the troubleshooting entry point for template swaps / column drift)

    It only opens the workbook read_only and never writes, and does no file selection or sorting.
    """
    if not os.path.isfile(path):
        raise OSError("workbook not found: %s" % path)
    wb = load_workbook(path, read_only=True, data_only=True)
    try:
        if sheet and sheet not in wb.sheetnames:
            raise ValueError("worksheet not found in workbook: %s" % sheet)
        targets = [sheet] if sheet else list(wb.sheetnames)
        print("File: %s" % os.path.abspath(path))
        for name in targets:
            grid = load_grid(wb[name], max_col=max_col)
            hdr = _trim_trailing_empty(header_row_grid(grid))
            print("[sheet] %s" % name)
            if not hdr:
                print("  (empty sheet or no header)")
                continue
            for i, h in enumerate(hdr):
                label = str(h).strip() if h is not None else ""
                kind = infer_column_type(
                    [row[i] if i < len(row) else None for row in grid[1:]])
                print("  column %d: %s (%s)" % (i + 1, label or "(empty column name)", kind))
    finally:
        wb.close()


def main(argv=None):
    p = argparse.ArgumentParser(description="Excel 只读读取层（表头探查）")
    p.add_argument("--dump", metavar="XLSX", help="只读打印每张工作表的列名与推断类型")
    p.add_argument("--sheet", default=None, help="只探查指定工作表")
    p.add_argument("--max-col", type=int, default=60, help="最多读取的列数（默认 60）")
    args = p.parse_args(argv)

    # The Windows console code page may not be UTF-8; reconfigure both streams before any non-ASCII output, which would otherwise raise
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    if not args.dump:
        p.print_help()
        return 2
    try:
        dump_workbook(args.dump, args.sheet, args.max_col)
    except Exception as exc:
        sys.stderr.write("[error] %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
