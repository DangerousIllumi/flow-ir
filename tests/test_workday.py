# -*- coding: utf-8 -*-
"""工作日历判定测试：is_workday / load_workdays / --is-workday 命令行

覆盖定时任务关心的三点：
  1. 日历标"否"的日期（法定节假日）判定为非工作日；
  2. 日历标"是"的日期（含调休上班的周末）判定为工作日；
  3. 日历缺失时按周一至周五兜底，并明确报告日历不可用（不让定时任务静默停摆）。
"""
import subprocess
import sys
from datetime import date, datetime, time, timedelta
from pathlib import Path

from openpyxl import Workbook

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "workday"))
import workday as reconcile  # 保留别名，测试体不用改；被测模块是通用件 # noqa: E402

RECONCILE = ROOT / "tools" / "workday" / "workday.py"


def _write_calendar(path, rows):
    """rows: [(相对今天的天数, 是否工作日)]"""
    wb = Workbook()
    ws = wb.active
    ws.title = "工作日"
    ws.append(["日期", "是否工作日"])
    today = date.today()
    for off, flag in rows:
        ws.append([datetime.combine(today + timedelta(days=off), time.min), flag])
    wb.save(str(path))


def test_workday_true_for_marked_day(tmp_path):
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (-1, "是")])
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_holiday_marked_no_is_not_workday(tmp_path):
    """法定节假日：日历标"否"，即使今天是周一到周五也不该跑"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否"), (-1, "是")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_single_holiday_row_counts_as_available_calendar(tmp_path):
    """只有一行且标"否"：日历有效、当天不是工作日，不能当成"日历不可用"走兜底"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_weekend_marked_yes_is_workday(tmp_path):
    """调休上班：日历标"是"，即使今天是周末也要跑"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是")])
    assert reconcile.is_workday(str(cal), date.today())[0] is True


def test_missing_calendar_falls_back_to_weekday(tmp_path):
    ok, has_cal = reconcile.is_workday(str(tmp_path / "nope.xlsx"), date.today())
    assert has_cal is False
    assert ok == (date.today().weekday() < 5)


def test_load_prev_workday_skips_holiday(tmp_path):
    """上一个工作日要跳过标"否"的日期"""
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
