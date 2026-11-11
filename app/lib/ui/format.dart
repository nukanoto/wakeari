const weekdayLabels = ['月', '火', '水', '木', '金', '土', '日'];

String two(int v) => v.toString().padLeft(2, '0');

String formatTime(int hour, int minute) => '${two(hour)}:${two(minute)}';

String formatClock(DateTime t) =>
    '${formatTime(t.hour, t.minute)}:${two(t.second)}';

const _weekdays = 0x1F;
const _weekend = 0x60;
const _everyday = 0x7F;

/// 曜日マスクの説明。0 -> "1回のみ"、0x1F -> "平日"、0x60 -> "土日"、0x7F -> "毎日"。
String repeatLabel(int mask) {
  switch (mask) {
    case 0:
      return '1回のみ';
    case _everyday:
      return '毎日';
    case _weekdays:
      return '平日';
    case _weekend:
      return '土日';
  }
  return [
    for (var i = 0; i < 7; i++)
      if ((mask >> i) & 1 == 1) weekdayLabels[i],
  ].join('・');
}

/// [at] が [now] の翌日までなら "今日" / "明日（木）"、それ以降は "金曜日"。
String dayLabel(DateTime at, DateTime now) {
  final days = DateTime(
    at.year,
    at.month,
    at.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  final w = weekdayLabels[at.weekday - 1];
  if (days <= 0) return '今日';
  if (days == 1) return '明日（$w）';
  return '$w曜日';
}

/// "次は 09:30（土）" の "09:30（土）" 部分。
String timeWithWeekday(DateTime at) =>
    '${formatTime(at.hour, at.minute)}（${weekdayLabels[at.weekday - 1]}）';

/// "あと 6時間12分" 形式（1 時間未満は分だけ、1 日以上は日と時間）。
String untilLabel(DateTime at, DateTime now) {
  final seconds = at.difference(now).inSeconds;
  final minutes = seconds <= 0 ? 0 : (seconds + 59) ~/ 60;
  if (minutes < 1) return 'まもなく';
  final d = minutes ~/ 1440;
  final h = (minutes % 1440) ~/ 60;
  final m = minutes % 60;
  if (d > 0) return 'あと $d日$h時間';
  if (h > 0) return m == 0 ? 'あと $h時間' : 'あと $h時間$m分';
  return 'あと $m分';
}

/// 60 -> "60秒"。ON の長さの表示用。
String formatSeconds(int seconds) => '$seconds秒';

/// 分単位のオフセットを "UTC+9" / "UTC+5:30" / "UTC-3" にする。
String formatUtcOffset(Duration offset) {
  final minutes = offset.inMinutes;
  final sign = minutes < 0 ? '-' : '+';
  final abs = minutes.abs();
  final h = abs ~/ 60;
  final m = abs % 60;
  return m == 0 ? 'UTC$sign$h' : 'UTC$sign$h:${two(m)}';
}
