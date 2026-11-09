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


def _write_calendar(path, rows, base=None):
    """rows: [(相对 base 的天数, 是否工作日)]；base 缺省为今天

    base 可指定绝对日期，用于构造“某个月的月末”这类与当前日期无关的场景。
    """
    wb = Workbook()
    ws = wb.active
    ws.title = "工作日"
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
    """法定节假日：日历标"否"，即使今天是周一到周五也不该跑"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否"), (-1, "是")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_single_holiday_row_counts_as_available_calendar(tmp_path):
    """只有一行且标"否"：日历有效、当天不是工作日，不能当成"日历不可用"走兜底"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "否")])
    assert reconcile.is_workday(str(cal), date.today()) == (False, True)


def test_calendar_in_range_reports_min_max(tmp_path):
    """今天在覆盖范围内：WORKDAY 按标记判断，并给出 CALENDAR_MIN / MAX"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-1, "是"), (0, "是")])
    ok, has_cal, stale, dmin, dmax = reconcile.is_workday_detail(str(cal), date.today())
    assert (ok, has_cal, stale) == (True, True, False)
    assert dmin == date.today() - timedelta(days=1)
    assert dmax == date.today()


def test_calendar_out_of_range_is_stale_not_rest(tmp_path):
    """日历最后一天早于今天：判定为过期，WORKDAY 不能表达成 0（休息）"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-30, "是"), (-5, "否")])
    detail = reconcile.is_workday_detail(str(cal), date.today())
    assert detail[2] is True, "今天超出日历范围必须标记 stale"
    assert detail[0] is True, "过期不能返回 WORKDAY=0"
    # 保留旧签名也不得把过期读成休息
    assert reconcile.is_workday(str(cal), date.today()) == (True, True)


def test_empty_calendar_is_available_but_not_workday(tmp_path):
    """只有表头、没有任何日期行：日历有效但今天不在表里，不判过期"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [])
    detail = reconcile.is_workday_detail(str(cal), date.today())
    assert detail == (False, True, False, None, None)


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


# ── 月末工作日判定：对应 pad-schedule 的 -RunIfLastWorkday ──────
# 两条路径（有日历 / 无日历）各自的真、假两侧都要覆盖：
# 只测“月末返回真”，漏写“今天本身必须是工作日”这个前提也照样能过。
# 用固定的 2026-10 构造场景，避免用例结果随运行日期漂移。

OCT_29 = date(2026, 10, 29)   # 周四
OCT_30 = date(2026, 10, 30)   # 周五，本月最后一个工作日
OCT_31 = date(2026, 10, 31)   # 周六，本月最后一天


def test_last_workday_true_for_month_end(tmp_path):
    """日历可用：今天是本月最后一个工作日 → 真"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (-1, "是")], base=OCT_30)
    assert reconcile.is_last_workday(str(cal), OCT_30) is True


def test_last_workday_false_in_middle_of_month(tmp_path):
    """日历可用：今天是工作日但本月还有更晚的工作日 → 假"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(0, "是"), (1, "是")], base=OCT_29)
    assert reconcile.is_last_workday(str(cal), OCT_29) is False


def test_last_workday_false_when_today_not_workday(tmp_path):
    """日历可用：今天不在工作日集合里（周末） → 假，即使本月已无更晚的工作日"""
    cal = tmp_path / "cal.xlsx"
    _write_calendar(cal, [(-1, "是")], base=OCT_31)
    assert reconcile.is_last_workday(str(cal), OCT_31) is False


def test_last_workday_true_without_calendar(tmp_path):
    """日历不可用：月末周五 → 按周一到周五兜底判真"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_30) is True


def test_last_workday_false_without_calendar_in_middle(tmp_path):
    """日历不可用：周四，本月剩余还有周五 → 兜底判假"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_29) is False


def test_last_workday_false_without_calendar_on_weekend(tmp_path):
    """日历不可用：周六 → 兜底判假"""
    assert reconcile.is_last_workday(str(tmp_path / "nope.xlsx"), OCT_31) is False
