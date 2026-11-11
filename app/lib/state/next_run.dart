import '../ble/protocol.dart';

/// 予約の次の実行予定。
class NextRun {
  const NextRun(this.slot, this.at);

  final Slot slot;

  /// 実行時刻（[nextRun] に渡した [DateTime] と同じタイムゾーン）。
  final DateTime at;
}

/// [now] 以降で最も早い、有効な予約の実行を返す。なければ null。
///
/// - 実行時刻が [now] と同じ瞬間なら「これから」とみなす。秒が進んだら過ぎたもの。
/// - 単発（曜日なし）は、次に来る時刻に 1 回だけ。
/// - 同時刻の予約は id が小さい方。
NextRun? nextRun(Iterable<Slot> slots, DateTime now) {
  NextRun? best;
  for (final slot in slots) {
    if (!slot.enabled) continue;
    final at = _nextOccurrence(slot, now);
    if (at == null) continue;
    if (best == null ||
        at.isBefore(best.at) ||
        (at.isAtSameMomentAs(best.at) && slot.id < best.slot.id)) {
      best = NextRun(slot, at);
    }
  }
  return best;
}

DateTime? _nextOccurrence(Slot slot, DateTime now) {
  // 同じ曜日の 1 週間後まで調べる（今日の時刻が過ぎている場合に備えて 8 日分）。
  for (var offset = 0; offset <= 7; offset++) {
    final day = DateTime(now.year, now.month, now.day + offset);
    if (!slot.isOneShot && !slot.repeatsOn(day.weekday)) continue;
    final at = DateTime(day.year, day.month, day.day, slot.hour, slot.minute);
    if (!at.isBefore(now)) return at;
  }
  return null;
}
