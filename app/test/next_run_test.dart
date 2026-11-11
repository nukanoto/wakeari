import 'package:flutter_test/flutter_test.dart';
import 'package:wakeari/ble/protocol.dart';
import 'package:wakeari/state/next_run.dart';

const mon = 1, tue = 2, wed = 4, thu = 8, fri = 16, sat = 32, sun = 64;
const weekdays = mon | tue | wed | thu | fri;

Slot slot(int id, int mask, int h, int m, {bool enabled = true}) =>
    Slot(id: id, enabled: enabled, weekdayMask: mask, hour: h, minute: m);

void main() {
  // 2026-11-11 は水曜日。
  final wedMorning = DateTime(2026, 11, 11, 6, 0);

  test('予約なしは null', () {
    expect(nextRun(const [], wedMorning), isNull);
  });

  test('無効なスロットは無視する', () {
    expect(nextRun([slot(0, 0x7F, 7, 0, enabled: false)], wedMorning), isNull);
  });

  test('毎日: 今日の未来の時刻', () {
    final r = nextRun([slot(0, 0x7F, 7, 0)], wedMorning)!;
    expect(r.at, DateTime(2026, 11, 11, 7, 0));
    expect(r.slot.id, 0);
  });

  test('毎日: 今日の時刻が過ぎていれば明日', () {
    final r = nextRun([slot(0, 0x7F, 5, 0)], wedMorning)!;
    expect(r.at, DateTime(2026, 11, 12, 5, 0));
  });

  test('曜日マスク: 平日を土曜に見ると月曜', () {
    final sat10 = DateTime(2026, 11, 14, 10, 0);
    final r = nextRun([slot(0, weekdays, 7, 0)], sat10)!;
    expect(r.at, DateTime(2026, 11, 16, 7, 0));
    expect(r.at.weekday, DateTime.monday);
  });

  test('曜日マスク: 土日は水曜から見て土曜', () {
    final r = nextRun([slot(0, sat | sun, 9, 30)], wedMorning)!;
    expect(r.at, DateTime(2026, 11, 14, 9, 30));
  });

  test('単発: 今日これから / 過ぎていれば明日', () {
    expect(
      nextRun([slot(0, 0, 22, 5)], wedMorning)!.at,
      DateTime(2026, 11, 11, 22, 5),
    );
    expect(
      nextRun([slot(0, 0, 5, 5)], wedMorning)!.at,
      DateTime(2026, 11, 12, 5, 5),
    );
  });

  test('今日と同じ曜日の 1 週間後に回る', () {
    // 水曜 12:00 に、水曜だけの 7:00 → 来週水曜。
    final r = nextRun([slot(0, wed, 7, 0)], DateTime(2026, 11, 11, 12, 0))!;
    expect(r.at, DateTime(2026, 11, 18, 7, 0));
  });

  test('月・年をまたぐ', () {
    final r = nextRun([slot(0, 0x7F, 1, 0)], DateTime(2026, 12, 31, 23, 0))!;
    expect(r.at, DateTime(2027, 1, 1, 1, 0));
  });

  test('複数スロットのうち最も早いもの', () {
    final r = nextRun([
      slot(0, 0x7F, 9, 0),
      slot(1, 0x7F, 6, 30),
      slot(2, 0x7F, 6, 15, enabled: false),
    ], wedMorning)!;
    expect(r.slot.id, 1);
    expect(r.at, DateTime(2026, 11, 11, 6, 30));
  });

  test('同時刻は id が小さい方', () {
    final r = nextRun([slot(5, 0x7F, 7, 0), slot(2, 0x7F, 7, 0)], wedMorning)!;
    expect(r.slot.id, 2);
  });

  test('同じ分: ちょうどなら今、秒が進んだら次回', () {
    final s = slot(0, 0x7F, 7, 0);
    expect(
      nextRun([s], DateTime(2026, 11, 11, 7, 0, 0))!.at,
      DateTime(2026, 11, 11, 7, 0),
    );
    expect(
      nextRun([s], DateTime(2026, 11, 11, 7, 0, 1))!.at,
      DateTime(2026, 11, 12, 7, 0),
    );
    expect(
      nextRun([s], DateTime(2026, 11, 11, 6, 59, 59))!.at,
      DateTime(2026, 11, 11, 7, 0),
    );
  });
}
