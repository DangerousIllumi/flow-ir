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

# Excel 读取层是通用件，实现在仓库 tools/xlsx/xlsx_io.py：
# 表头定位、日期转换等口径全仓库共用一份，避免各写一份后漂移。
# 源码树里位于 tools/workday/，部署后可能与 xlsx_io.py 同目录或放在上一级。
_here = os.path.dirname(os.path.abspath(__file__))
for _cand in (os.path.join(_here, "..", "xlsx"), _here):
    if os.path.isfile(os.path.join(_cand, "xlsx_io.py")):
        sys.path.insert(0, _cand)
        break
from xlsx_io import norm, to_date, find_col  # noqa: E402

# 日历里代表「上班」的写法，大小写不敏感
TRUE_FLAGS = ("Y", "YES", "TRUE", "1", "是", "工作日")


def _sheet_priority(name):
    """页签选择优先级：中文「工作日」优先，英文 workday / working day 作为别名"""
    if "工作日" in name:
        return 2
    low = name.lower()
    if "workday" in low or "working day" in low:
        return 1
    return 0


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
        # 优先选名字里含「工作日」的表，其次英文 workday / working day，都没有则用第一个表
        ws = wb[max(wb.sheetnames, key=_sheet_priority)]
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
