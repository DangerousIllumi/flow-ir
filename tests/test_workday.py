# -*- coding: utf-8 -*-
"""Workday calendar tests: is_workday / load_workdays / the --is-workday CLI

Covers the three points scheduled jobs care about:
  1. dates the calendar marks as non-working (public holidays) are judged non-working;
  2. dates the calendar marks as working (including make-up working weekends) are judged working;
  3. when the calendar is missing, fall back to Monday-Friday and explicitly report that the calendar
     is unavailable, so scheduled jobs never silently stop running.
"""
import subprocess
import sys
from datetime import date, datetime, time, timedelta
from pathlib import Path

from openpyxl import Workbook

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "workday"))
import workday as reconcile  # keep the alias so test bodies stay untouched; the module under test is general-purpose  # noqa: E402

RECONCILE = ROOT / "tools" / "workday" / "workday.py"


def _write_calendar(path, rows, base=None, sheet="工作日", decoy=None):
    """rows: [(day offset from base, working flag)]; base defaults to today

    base may be an absolute date, which builds scenarios independent of the current date,
    such as "the last day of a given month". sheet overrides the sheet name; decoy first
    creates an empty sheet with that name, proving the reader does not simply take the first sheet.
    """
    wb = Workbook()
    ws = wb.active
    if decoy:
        ws.title = decoy
        ws = wb.create_sheet(sheet)
    else:
        ws.title = sheet
    ws.append(["日期", "是否工作日"])
    start = base or date.today()
    for off, flag in rows:
        ws.append([datetime.combine(start + timedelta(days=off), time.min), flag])
    wb.save(str(path))


def test_workday_true_for_marked_day(tmp_path):
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (-1, "是")])
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_holiday_marked_no_is_not_workday(tmp_path):
    """Public holiday: the calendar marks it non-working, so it must not run even on a Monday-Friday"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否"), (-1, "是")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_single_holiday_row_counts_as_available_calendar(tmp_path):
    """Single row marked non-working: the calendar is valid and today is just not a working day, so this
    must not be mistaken for "calendar unavailable" and take the fallback path"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_calendar_in_range_reports_min_max(tmp_path):
    """Today is within the covered range: WORKDAY follows the markers and CALENDAR_MIN / MAX are reported"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-1, "是"), (0, "是")])
    ok, has_cal, stale, dmin, dmax = reconcile.is_workday_detail(str(cal), date.today())
    assert (ok, has_cal, stale) == (True, True, False)
    assert dmin == date.today() - timedelta(days=1)
    assert dmax == date.today()


def test_calendar_out_of_range_is_stale_not_rest(tmp_path):
    """The calendar's last day is before today: report it as stale, and WORKDAY must not collapse to 0 (rest)"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-30, "是"), (-5, "否")])
    detail = reconcile.is_workday_detail(str(cal), date.today())
    assert detail[2] is True, "今天超出日历范围必须标记 stale"
    assert detail[0] is True, "过期不能返回 WORKDAY=0"
    # The legacy signature must not report a stale calendar as rest either
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_empty_calendar_is_available_but_not_workday(tmp_path):
    """Header only, no date rows: the calendar is valid, today is simply absent from it, and it is not stale"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [])
    detail = reconcile.is_workday_detail(str(cal), date.today())
    assert detail == (False, True, False, None, None)


def test_weekend_marked_yes_is_workday(tmp_path):
    """Make-up working day: the calendar marks it working, so it must run even on a weekend"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是")])
    assert reconcile.is_workday(str(cal), date.today())[0] is True


def test_chinese_sheet_still_recognized_with_english_decoy_first(tmp_path):
    """A Chinese sheet name is still recognized, and it wins over an English sheet listed before it"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是")], decoy="Workday")
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_english_sheet_alias_recognized(tmp_path):
    """An English sheet named Workday is accepted as an alias"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是")], sheet="Workday")
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_missing_calendar_falls_back_to_weekday(tmp_path):
    ok, has_cal = reconcile.is_workday(str(tmp_path / "nope.xlsx"), date.today())
    assert has_cal is False
    assert ok == (date.today().weekday() < 5)


def test_load_prev_workday_skips_holiday(tmp_path):
    """The previous workday must skip dates marked non-working"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-1, "否"), (-2, "是"), (-3, "是")])
    assert reconcile.load_prev_workday(str(cal), date.today()) == date.today() - timedelta(days=2)


def test_cli_is_workday_outputs_flag(tmp_path):
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是")])
    proc = subprocess.run([sys.executable, str(RECONCILE), "--is-workday", "--calendar", str(cal)],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    assert proc.returncode == 0
    assert "WORKDAY=1" in proc.stdout
    assert "CALENDAR_OK=1" in proc.stdout


def test_cli_is_workday_reports_missing_calendar(tmp_path):
    proc = subprocess.run([sys.executable, str(RECONCILE), "--is-workday",
                           "--calendar", str(tmp_path / "nope.xlsx")],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    assert proc.returncode == 0
    assert "CALENDAR_OK=0" in proc.stdout
    assert "WORKDAY=" in proc.stdout


# ── Month-end workday check: mirrors -RunIfLastWorkday in pad-schedule ──────
# Both paths (calendar present / calendar absent) need coverage on their true and false side:
# testing only "the last day of the month returns true" would still pass if the precondition
# "today itself must be a working day" were missing.
# Scenarios use fixed dates in October 2026 so results do not drift with the run date.

OCT_29 = date(2026, 10, 29)   # Thursday
OCT_30 = date(2026, 10, 30)   # Friday, the month's last working day
OCT_31 = date(2026, 10, 31)   # Saturday, the month's last day


def test_last_workday_true_for_month_end(tmp_path):
    """Calendar available: today is the month's last working day -> true"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (-1, "是")], base=OCT_30)
    assert reconcile.is_last_workday(str(cal), OCT_30) is True


def test_last_workday_false_in_middle_of_month(tmp_path):
    """Calendar available: today is a working day but a later working day remains in the month -> false"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (1, "是")], base=OCT_29)
    assert reconcile.is_last_workday(str(cal), OCT_29) is False


def test_last_workday_false_when_today_not_workday(tmp_path):
    """Calendar available: today is not in the working set (weekend) -> false, even though no later
    working day remains in the month"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-1, "是")], base=OCT_31)
    assert reconcile.is_last_workday(str(cal), OCT_31) is False


def test_last_workday_true_without_calendar(tmp_path):
    """Calendar unavailable: month-end Friday -> the Monday-Friday fallback returns true"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_30) is True


def test_last_workday_false_without_calendar_in_middle(tmp_path):
    """Calendar unavailable: Thursday with Friday still left in the month -> the fallback returns false"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_29) is False


def test_last_workday_false_without_calendar_on_weekend(tmp_path):
    """Calendar unavailable: Saturday -> the fallback returns false"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_31) is False
