# -*- coding: utf-8 -*-
"""workday.py — 工作日历工具（通用件，不含任何业务核对规则）

读一份「日期 / 是否工作日」两列的 xlsx 日历，回答两个问题：
  1. 今天是不是工作日（日历不可用时按周一至周五兜底）
  2. 上一个工作日是哪天

中国节假日与调休都体现在日历的这一列：节假日标「否」，调休上班的周末标「是」。

CLI（与调度脚本的约定一致）：
  python workday.py --is-workday   --calendar cal.xlsx
      -> CALENDAR_OK=1/0 + WORKDAY=1/0
  python workday.py --prev-workday --calendar cal.xlsx
      -> PREV_WORKDAY=YYYY-MM-DD（读不到日历时按周一至周五倒推）
  python workday.py --is-last-workday --calendar cal.xlsx
      -> LAST_WORKDAY=1/0（今天是否本月最后一个工作日）
"""
import argparse
import os
import sys
from datetime import date, datetime, timedelta

from openpyxl import load_workbook

# 日历里代表「上班」的写法，大小写不敏感
TRUE_FLAGS = ("Y", "YES", "TRUE", "1", "是", "工作日")


def norm(v):
    """把任意单元格值规整成用于表头匹配的字符串（去空白 + 小写）"""
    return str(v).strip().lower() if v is not None else ""


def to_date(v):
    """把单元格值转成 date：支持 datetime / date / Excel 序列号 / 常见字符串日期"""
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
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d", "%d.%m.%Y", "%d/%m/%Y", "%Y%m%d"):
        try:
            return datetime.strptime(s, fmt).date()
        except Exception:
            continue
    return None


def find_col(header, names, prefix=None):
    """在表头行中按名称找列号（1 起）。names 精确匹配，prefix 作前缀兜底。"""
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


def load_calendar(cal_path):
    """读取日历，返回 (工作日集合, 最小日期, 最大日期)

    最小/最大日期按「所有能解析出日期的行」统计，不是只统计工作日：
    这样日历哪天开始、哪天结束一目了然，用来判断日历是否已过期。
    日历不可用或表头识别失败时返回 (None, None, None)。
    """
    if not cal_path or not os.path.isfile(cal_path):
        return (None, None, None)
    wb = load_workbook(cal_path, data_only=True)
    try:
        # 优先选名字里含「工作日」的表，否则用第一个表
        ws = next((wb[s] for s in wb.sheetnames if "工作日" in s), wb[wb.sheetnames[0]])
        c_date = c_wd = None
        hdr = 0
        # 在前 10 行内找表头行（同时含「日期」和「是否工作日」）
        for r in range(1, min(ws.max_row, 10) + 1):
            vals = [ws.cell(row=r, column=c).value for c in range(1, min(ws.max_column, 10) + 1)]
            d = find_col(vals, ["日期"], prefix="日期")
            w = find_col(vals, ["是否工作日", "工作日", "是否上班"], prefix="是否工作日")
            if d and w:
                c_date, c_wd, hdr = d, w, r
                break
        if not c_date:
            return (None, None, None)
        days = set()
        all_dates = []
        for r in range(hdr + 1, ws.max_row + 1):
            dv = to_date(ws.cell(row=r, column=c_date).value)
            if dv is None:
                continue
            all_dates.append(dv)
            wv = ws.cell(row=r, column=c_wd).value
            flag = str(wv).strip().upper() if wv is not None else ""
            if flag in TRUE_FLAGS:
                days.add(dv)
        if not all_dates:
            return (days, None, None)
        return (days, min(all_dates), max(all_dates))
    finally:
        wb.close()


def load_workdays(cal_path):
    """只取工作日集合（保留旧签名，供既有调用方使用）"""
    return load_calendar(cal_path)[0]


def calendar_state(cal_path, today):
    """返回日历状态：{days, min, max, stale}；日历不可用时返回 None

    stale 表示今天落在日历覆盖范围之外：此时不能把「表里没有今天」解释成休息，
    否则日历过期会让定时任务静默跳过。
    """
    days, dmin, dmax = load_calendar(cal_path)
    if days is None:
        return None
    stale = bool(dmin is not None and dmax is not None and (today < dmin or today > dmax))
    return {"days": days, "min": dmin, "max": dmax, "stale": stale}



def load_prev_workday(cal_path, today):
    """从工作日历读出「上一个工作日」（严格早于 today 的最近一个工作日）"""
    days = load_workdays(cal_path)
    if not days:
        return None
    prev = [d for d in days if d < today]
    return max(prev) if prev else None


def is_workday_detail(cal_path, today):
    """返回 (是否工作日, 日历可用, 日历过期, 最小日期, 最大日期)

    日历过期时 WORKDAY 必须为 1（不能表达成「今天休息」），由调用方硬失败。
    """
    state = calendar_state(cal_path, today)
    if state is None:
        return (today.weekday() < 5, False, False, None, None)
    if state["stale"]:
        return (True, True, True, state["min"], state["max"])
    return (today in state["days"], True, False, state["min"], state["max"])


def is_workday(cal_path, today):
    """判断 today 是否工作日，返回 (是否工作日, 日历是否可用)"""
    detail = is_workday_detail(cal_path, today)
    return (detail[0], detail[1])


def prev_workday_by_weekday(today):
    """日历不可用时的兜底：按周一至周五倒推上一个工作日（不识别法定节假日）"""
    d = today - timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return d


def is_last_workday(cal_path, today):
    """判断 today 是否当前月份的最后一个工作日

    日历可用时：今天本身必须是工作日，且本月没有更晚的工作日。
    日历不可用时按周一到周五兜底：今天是工作日，且本月剩余日期里没有工作日。
    """
    days = load_workdays(cal_path)
    if days is None:
        if today.weekday() >= 5:
            return False
        d = today + timedelta(days=1)
        while d.month == today.month:
            if d.weekday() < 5:
                return False
            d += timedelta(days=1)
        return True
    if today not in days:
        return False
    return not any(d.month == today.month and d > today for d in days)


def main(argv=None):
    p = argparse.ArgumentParser(description="工作日历判断（通用）")
    p.add_argument("--calendar", default="", help="工作日历 xlsx")
    p.add_argument("--is-workday", action="store_true", help="打印 CALENDAR_OK / WORKDAY")
    p.add_argument("--prev-workday", action="store_true", help="打印 PREV_WORKDAY")
    p.add_argument("--is-last-workday", action="store_true", help="打印 LAST_WORKDAY")
    args = p.parse_args(argv)
    today = date.today()
    if args.is_last_workday:
        print("LAST_WORKDAY=%d" % (1 if is_last_workday(args.calendar, today) else 0))
        return 0
    if args.is_workday:
        ok, has_cal, stale, dmin, dmax = is_workday_detail(args.calendar, today)
        print("CALENDAR_OK=%d" % (1 if has_cal else 0))
        print("WORKDAY=%d" % (1 if ok else 0))
        print("CALENDAR_STALE=%d" % (1 if stale else 0))
        print("CALENDAR_MIN=%s" % (dmin.isoformat() if dmin else ""))
        print("CALENDAR_MAX=%s" % (dmax.isoformat() if dmax else ""))
        return 0
    if args.prev_workday:
        d = load_prev_workday(args.calendar, today) or prev_workday_by_weekday(today)
        print("PREV_WORKDAY=%s" % d.isoformat())
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
