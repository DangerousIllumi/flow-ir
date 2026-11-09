# -*- coding: utf-8 -*-
"""xlsx_io.py — Excel 只读读取层（通用件，不含任何业务规则）

仓库里所有读取 xlsx 的脚本共用这一份实现，避免各写一份之后口径漂移。
本模块只做只读读取：不写单元格、不改文件、不维护模块级可变状态。

对外函数：
  norm(v)                        单元格值 -> 表头匹配用字符串（去空白 + 小写）
  find_col(header, names, prefix=None)
                                 按表头名定位列号（1 起）：精确匹配优先，前缀兜底
  to_date(v)                     宽松日期转换（datetime / date / Excel 序列号 / 常见字符串）
  parse_number(v)                宽松数值转换，返回 (值, 状态)
                                 状态 number=数值 / empty=空 / invalid=非法
  to_number(v)                   旧口径数值转换：空与非法统一返回 None（兼容既有调用方）
  load_grid(ws, max_col=60)      工作表 -> 二维列表（只读流式读取）
  header_row_grid(grid)          二维列表的表头行
  read_rule_table(ws, ...)       规则页签 -> 字典（纯函数，不写模块级全局变量）
  infer_column_type(values)      按单元格存储类型推断列类型（供表头探查使用）

CLI（只读排障，换模板 / 列漂移时用）：
  python xlsx_io.py --dump <工作簿> [--sheet <表名>] [--max-col N]
      打印每张工作表的列名与推断类型，不修改文件。
"""
import argparse
import os
import sys
from datetime import date, datetime, timedelta

from openpyxl import load_workbook

# 数值转换的三种状态：空（没填）与非法（填了但解析不了）必须区分，
# 一律吞成 0 会把脏数据伪装成合法数值，掩盖上游问题。
NUMBER = "number"
EMPTY = "empty"
INVALID = "invalid"

# 常见日期字符串写法（与历史调用方保持一致，不新增格式以免改变既有判定）
DATE_FORMATS = ("%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d", "%d.%m.%Y", "%d/%m/%Y", "%Y%m%d")


def norm(v):
    """把任意单元格值规整成用于表头匹配的字符串（去空白 + 小写）"""
    return str(v).strip().lower() if v is not None else ""


def find_col(header, names, prefix=None):
    """在表头行中按名称找列号（1 起）。names 精确匹配，prefix 作前缀兜底。

    先按 names 的顺序逐个精确匹配，全部不中才用前缀匹配；
    返回 None 表示表头里没有这一列（调用方须自行决定是硬失败还是可缺省）。
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
    """把单元格值转成 date：支持 datetime / date / Excel 序列号 / 常见字符串日期

    解析不出来返回 None（保持历史口径：调用方把 None 当作「无法解析」而跳过筛选，
    不能在这里改判成任何默认日期）。
    """
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    if isinstance(v, (int, float)):
        # Excel 序列号：以 1899-12-30 为原点
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
    """把单元格值转成 (数值, 状态)

    状态：
      number  —— 解析成功，第一项是 float
      empty   —— 空单元格 / 空白字符串，第一项为 None
      invalid —— 填了内容但解析不成数值，第一项为 None

    区分 empty 与 invalid 是本层的硬要求：脏数据不能被悄悄当成 0 或空。
    """
    if v is None:
        return None, EMPTY
    if isinstance(v, str) and not v.strip():
        return None, EMPTY
    if isinstance(v, (int, float)):
        # 布尔是 int 的子类，历史实现按 1/0 处理，这里保持一致
        return float(v), NUMBER
    try:
        return float(str(v).strip().replace(",", "")), NUMBER
    except Exception:
        return None, INVALID


def to_number(v):
    """旧口径数值转换：解析失败与空值都返回 None

    仅供既有调用方保持行为不变；新代码若要区分「空」与「非法」，用 parse_number。
    """
    return parse_number(v)[0]


def load_grid(ws, max_col=60):
    """把工作表读成二维列表（下标 0 起）

    固定只读到前 max_col 列：真实报表的格式残留会让 max_column 达到上万，
    全读会把空列也装进内存。表头与业务列都远在这个范围内。
    只遍历一次（read_only 每次 iter_rows 都要重新解析整张表，分两次会翻倍）。
    """
    grid = []
    for row in ws.iter_rows(min_col=1, max_col=max_col, values_only=True):
        grid.append(list(row))
    return grid


def header_row_grid(grid):
    """表头行（二维列表的第 1 行）；空表返回空列表"""
    return list(grid[0]) if grid else []


def _trim_trailing_empty(header):
    """去掉表头尾部连续的空列，避免打印几十个无意义的「空列名」"""
    i = len(header)
    while i > 0 and norm(header[i - 1]) == "":
        i -= 1
    return header[:i]


def infer_column_type(values, sample=20):
    """按单元格的存储类型推断一列的类型（只抽样前 sample 个非空值）

    判定口径只看单元格在文件里的存储类型，不把字符串再解析成日期：
      date/datetime -> 日期；int/float -> 数值；其余 -> 文本；
      非空值类型不唯一 -> 混合；全是空值 -> 空。
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
    """把「项目 / 值 / 单位 / 说明」这类页签读成规则字典（纯函数）

    返回 {项目值: {"value": 值, "unit": 单位, "note": 说明}}；
    三个字段都保留单元格原始值，不做数值转换（规则值可能是百分号、代码等）。

    约定：
      - 表头行默认取第 1 行（下标 0），空表返回 {}；
      - 「项目」「值」两列缺失直接报错，列名漂移不能静默读成空字典；
      - 「单位」「说明」可选，缺列时对应字段记 None；
      - 项目值重复直接报错（歧义即失败，不静默取最后一行）。
    """
    grid = load_grid(ws, max_col=max_col)
    if header_row >= len(grid):
        return {}
    hdr = grid[header_row]
    # 整行表头都为空 = 空白页签，直接返回空字典，不按「缺列」报错
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
    """只读打印工作簿的列名与推断类型（换模板 / 列漂移时的排障入口）

    只打开 read_only 工作簿、只读不写，也不做任何文件挑选或排序。
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

    # Windows 控制台代码页可能不是 UTF-8，中文输出前统一改编码，避免直接抛错
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
