# -*- coding: utf-8 -*-
"""workday.py — working-calendar tool (generic; contains no business checking rules)

Reads an xlsx calendar with two columns, date / is-workday, and answers two questions:
  1. is today a workday (falling back to Monday-Friday when the calendar is unavailable)
  2. which day was the previous workday

Chinese holidays and make-up workdays both show up in that calendar column: a holiday reads "no", a weekend worked as a make-up day reads "yes".

CLI (matching the convention used by the scheduling scripts):
  python workday.py --is-workday   --calendar cal.xlsx
      -> CALENDAR_OK=1/0 + WORKDAY=1/0
  python workday.py --prev-workday --calendar cal.xlsx
      -> PREV_WORKDAY=YYYY-MM-DD (counts back over Monday-Friday when the calendar is unreadable)
  python workday.py --is-last-workday --calendar cal.xlsx
      -> LAST_WORKDAY=1/0 (whether today is the last workday of this month)
"""
import argparse
import os
import sys
from datetime import date, datetime, timedelta

from openpyxl import load_workbook

# The Excel access layer is a generic piece implemented in the repository at tools/xlsx/xlsx_io.py:
# header lookup, date conversion and the like live in exactly one place, so separate copies cannot drift apart.
# In the source tree it sits under tools/workday/, but once deployed it may be beside xlsx_io.py or one level up.
_here = os.path.dirname(os.path.abspath(__file__))
for _cand in (os.path.join(_here, "..", "xlsx"), _here):
    if os.path.isfile(os.path.join(_cand, "xlsx_io.py")):
        sys.path.insert(0, _cand)
        break
from xlsx_io import norm, to_date, find_col  # noqa: E402

# Spellings that mean "working day" in the calendar, matched case-insensitively
TRUE_FLAGS = ("Y", "YES", "TRUE", "1", "是", "工作日")


def _sheet_priority(name):
    """Sheet selection priority: a Chinese workday sheet wins, English workday / working day are aliases"""
    if "工作日" in name:
        return 2
    low = name.lower()
    if "workday" in low or "working day" in low:
        return 1
    return 0


def load_calendar(cal_path):
    """Read the calendar and return (set of workdays, earliest date, latest date)

    The earliest/latest dates are computed over every row with a parsable date, not over the workdays only:
    that makes the calendar's coverage visible at a glance, which is how a stale calendar is detected.
    Returns (None, None, None) when the calendar is unusable or the header cannot be recognised.
    """
    if not cal_path or not os.path.isfile(cal_path):
        return (None, None, None)
    wb = load_workbook(cal_path, data_only=True)
    try:
        # Prefer a sheet whose name mentions workdays, then English workday / working day, otherwise the first sheet
        ws = wb[max(wb.sheetnames, key=_sheet_priority)]
        c_date = c_wd = None
        hdr = 0
        # Look for the header row (holding both "date" and "is workday") within the first 10 rows
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
    """Return the workday set only (the old signature, kept for existing callers)"""
    return load_calendar(cal_path)[0]


def calendar_state(cal_path, today):
    """Return the calendar state: {days, min, max, stale}; None when the calendar is unusable

    stale means today falls outside the calendar's coverage: "today is not in the table" must not be
    read as a day off, because an expired calendar would then make scheduled jobs skip silently.
    """
    days, dmin, dmax = load_calendar(cal_path)
    if days is None:
        return None
    stale = bool(dmin is not None and dmax is not None and (today < dmin or today > dmax))
    return {"days": days, "min": dmin, "max": dmax, "stale": stale}



def load_prev_workday(cal_path, today):
    """Read the previous workday from the calendar (the latest workday strictly before today)"""
    days = load_workdays(cal_path)
    if not days:
        return None
    prev = [d for d in days if d < today]
    return max(prev) if prev else None


def is_workday_detail(cal_path, today):
    """Return (is workday, calendar available, calendar stale, earliest date, latest date)

    When the calendar is stale, WORKDAY must be 1 (it can never be expressed as "today is a day off"); the caller fails hard instead.
    """
    state = calendar_state(cal_path, today)
    if state is None:
        return (today.weekday() < 5, False, False, None, None)
    if state["stale"]:
        return (True, True, True, state["min"], state["max"])
    return (today in state["days"], True, False, state["min"], state["max"])


def is_workday(cal_path, today):
    """Decide whether today is a workday; returns (is workday, calendar available)"""
    detail = is_workday_detail(cal_path, today)
    return (detail[0], detail[1])


def prev_workday_by_weekday(today):
    """Fallback when the calendar is unavailable: step back over Monday-Friday (public holidays are not recognised)"""
    d = today - timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return d


def is_last_workday(cal_path, today):
    """Decide whether today is the last workday of its month

    With a usable calendar: today must itself be a workday, and no later workday may exist in the month.
    Without a calendar, fall back to Monday-Friday: today is a weekday and no weekday remains this month.
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
