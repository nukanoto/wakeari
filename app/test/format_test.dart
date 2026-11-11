import 'package:flutter_test/flutter_test.dart';
import 'package:wakeari/ui/format.dart';

void main() {
  test('repeatLabel', () {
    expect(repeatLabel(0), '1回のみ');
    expect(repeatLabel(0x7F), '毎日');
    expect(repeatLabel(0x1F), '平日');
    expect(repeatLabel(0x60), '土日');
    expect(repeatLabel(0x15), '月・水・金');
  });

  test('dayLabel', () {
    final now = DateTime(2026, 11, 11, 22, 0); // 水
    expect(dayLabel(DateTime(2026, 11, 11, 23, 0), now), '今日');
    expect(dayLabel(DateTime(2026, 11, 12, 7, 0), now), '明日（木）');
    expect(dayLabel(DateTime(2026, 11, 13, 7, 0), now), '金曜日');
  });

  test('untilLabel', () {
    final now = DateTime(2026, 11, 11, 0, 48);
    expect(untilLabel(DateTime(2026, 11, 11, 7, 0), now), 'あと 6時間12分');
    expect(untilLabel(DateTime(2026, 11, 11, 1, 0), now), 'あと 12分');
    expect(untilLabel(DateTime(2026, 11, 11, 3, 48), now), 'あと 3時間');
    expect(untilLabel(DateTime(2026, 11, 12, 3, 48), now), 'あと 1日3時間');
    expect(untilLabel(now, now), 'まもなく');
  });

  test('formatUtcOffset', () {
    expect(formatUtcOffset(const Duration(hours: 9)), 'UTC+9');
    expect(formatUtcOffset(const Duration(hours: 5, minutes: 30)), 'UTC+5:30');
    expect(formatUtcOffset(const Duration(hours: -3)), 'UTC-3');
  });
}
