import 'dart:convert';
import 'dart:typed_data';

/// wakeari BLE GATT プロトコル（docs/protocol.md）の純 Dart 実装。
/// 多バイト値はすべて little-endian。

const String serviceUuid = '9643763d-ca0d-45be-bae0-e3d2170256fe';
const String timeUuid = '59049d1c-3f43-4b9a-b9cd-ff479d454afa';
const String commandUuid = '6e0e3b6f-0aa8-40ad-855e-d527c4ce7e2e';
const String statusUuid = '5eb782eb-b27c-4a34-ac18-03cf8f2ad6ff';
const String schedulesUuid = '75f7c1b1-0233-4282-a2d0-0932961212a8';
const String configUuid = '8dbfbc93-2938-4495-a466-b2c67133bfd4';
const String nameUuid = '85fae2ad-ab1d-436a-922b-a3435a12154b';

const int maxSlots = 8;
const int minDurationSeconds = 1;
const int maxDurationSeconds = 3600;
const int defaultDurationSeconds = 30;
const int slotSize = 5;
const int statusSize = 13;
const int timeSize = 10;
const int configSize = 2;

/// Name の最大バイト数（スキャン応答に載せられる上限）。日本語なら全角 9 文字。
const int nameMaxBytes = 29;

/// Status の `active_slot` が「予約で ON ではない」ことを表す値。
const int noActiveSlot = 0xFF;

/// プロトコル違反（範囲外の値・不正な長さ）。
class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

void _check(bool ok, String message) {
  if (!ok) throw ProtocolException(message);
}

/// Config characteristic（2 bytes）: 1 回の ON の長さ（秒）。
Uint8List encodeConfig(int durationSeconds) {
  _check(
    durationSeconds >= minDurationSeconds &&
        durationSeconds <= maxDurationSeconds,
    'duration_s は $minDurationSeconds〜$maxDurationSeconds: $durationSeconds',
  );
  final data = ByteData(configSize)
    ..setUint16(0, durationSeconds, Endian.little);
  return data.buffer.asUint8List();
}

int decodeConfig(List<int> bytes) {
  _check(
    bytes.length == configSize,
    'Config は $configSize bytes: ${bytes.length}',
  );
  final seconds = ByteData.sublistView(
    Uint8List.fromList(bytes),
  ).getUint16(0, Endian.little);
  _check(
    seconds >= minDurationSeconds && seconds <= maxDurationSeconds,
    'duration_s は $minDurationSeconds〜$maxDurationSeconds: $seconds',
  );
  return seconds;
}

/// 名前の検証結果。
enum NameIssue { empty, tooLong, controlChar }

bool _isControl(int rune) => rune <= 0x1F || rune == 0x7F;

/// 前後の空白を除いた名前を返す。
String trimName(String name) => name.trim();

/// 問題がなければ null。前後の空白は無視して判定する。
NameIssue? checkName(String name) {
  final trimmed = trimName(name);
  if (trimmed.runes.any(_isControl)) return NameIssue.controlChar;
  final length = utf8.encode(trimmed).length;
  if (length < 1) return NameIssue.empty;
  if (length > nameMaxBytes) return NameIssue.tooLong;
  return null;
}

/// Name characteristic（1〜29 bytes, UTF-8, 終端 NUL なし）。
Uint8List encodeName(String name) {
  final issue = checkName(name);
  _check(issue == null, switch (issue) {
    NameIssue.empty => '名前が空です',
    NameIssue.tooLong => '名前は $nameMaxBytes bytes まで',
    NameIssue.controlChar => '名前に制御文字は使えません',
    null => '',
  });
  return Uint8List.fromList(utf8.encode(trimName(name)));
}

String decodeName(List<int> bytes) {
  _check(
    bytes.isNotEmpty && bytes.length <= nameMaxBytes,
    'Name は 1〜$nameMaxBytes bytes: ${bytes.length}',
  );
  final String name;
  try {
    name = utf8.decode(bytes);
  } on FormatException {
    throw ProtocolException('Name が UTF-8 ではありません');
  }
  _check(!name.runes.any(_isControl), 'Name に制御文字が含まれています');
  return name;
}

/// Time characteristic（10 bytes）。
class TimeSync {
  const TimeSync({required this.epochSeconds, required this.tzOffsetMinutes});

  /// 現在の時刻から生成する。
  factory TimeSync.fromDateTime(DateTime now) => TimeSync(
    epochSeconds: now.millisecondsSinceEpoch ~/ 1000,
    tzOffsetMinutes: now.timeZoneOffset.inMinutes,
  );

  final int epochSeconds;
  final int tzOffsetMinutes;

  Uint8List encode() {
    _check(
      tzOffsetMinutes >= -32768 && tzOffsetMinutes <= 32767,
      'tz は i16 の範囲外: $tzOffsetMinutes',
    );
    final data = ByteData(timeSize);
    data.setInt64(0, epochSeconds, Endian.little);
    data.setInt16(8, tzOffsetMinutes, Endian.little);
    return data.buffer.asUint8List();
  }

  static TimeSync decode(List<int> bytes) {
    _check(bytes.length == timeSize, 'Time は $timeSize bytes: ${bytes.length}');
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    return TimeSync(
      epochSeconds: data.getInt64(0, Endian.little),
      tzOffsetMinutes: data.getInt16(8, Endian.little),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TimeSync &&
      other.epochSeconds == epochSeconds &&
      other.tzOffsetMinutes == tzOffsetMinutes;

  @override
  int get hashCode => Object.hash(epochSeconds, tzOffsetMinutes);
}

/// Command characteristic のペイロード。
sealed class Command {
  const Command();

  Uint8List encode();

  static Command decode(List<int> bytes) {
    _check(bytes.isNotEmpty && bytes.length <= 6, 'Command は 1〜6 bytes');
    final data = Uint8List.fromList(bytes);
    switch (data[0]) {
      case 0x01:
        _check(data.length == 1, 'ON は 1 byte');
        return const CommandOn();
      case 0x02:
        _check(data.length == 1, 'OFF は 1 byte');
        return const CommandOff();
      case 0x10:
        _check(data.length == 1 + slotSize, 'PUT は ${1 + slotSize} bytes');
        return CommandPut(Slot.decode(data.sublist(1)));
      case 0x11:
        _check(data.length == 2, 'DELETE は 2 bytes');
        return CommandDelete(data[1]);
      case 0x12:
        _check(data.length == 1, 'CLEAR は 1 byte');
        return const CommandClear();
      default:
        throw ProtocolException('未知の opcode: 0x${data[0].toRadixString(16)}');
    }
  }
}

/// 即時 ON（Config の duration_s 秒後に自動 OFF）。
class CommandOn extends Command {
  const CommandOn();

  @override
  Uint8List encode() => Uint8List.fromList([0x01]);

  @override
  bool operator ==(Object other) => other is CommandOn;

  @override
  int get hashCode => 0x01;
}

/// 即時 OFF。
class CommandOff extends Command {
  const CommandOff();

  @override
  Uint8List encode() => Uint8List.fromList([0x02]);

  @override
  bool operator ==(Object other) => other is CommandOff;

  @override
  int get hashCode => 0x02;
}

/// スロットの追加・上書き。
class CommandPut extends Command {
  const CommandPut(this.slot);
  final Slot slot;

  @override
  Uint8List encode() => Uint8List.fromList([0x10, ...slot.encode()]);

  @override
  bool operator ==(Object other) => other is CommandPut && other.slot == slot;

  @override
  int get hashCode => Object.hash('put', slot);
}

/// スロットの削除。
class CommandDelete extends Command {
  const CommandDelete(this.id);
  final int id;

  @override
  Uint8List encode() {
    _check(id >= 0 && id < maxSlots, 'id は 0〜${maxSlots - 1}: $id');
    return Uint8List.fromList([0x11, id]);
  }

  @override
  bool operator ==(Object other) => other is CommandDelete && other.id == id;

  @override
  int get hashCode => Object.hash('delete', id);
}

/// 全スロットの削除。
class CommandClear extends Command {
  const CommandClear();

  @override
  Uint8List encode() => Uint8List.fromList([0x12]);

  @override
  bool operator ==(Object other) => other is CommandClear;

  @override
  int get hashCode => 0x12;
}

/// スケジュールスロット（5 bytes）。
class Slot {
  const Slot({
    required this.id,
    required this.enabled,
    required this.weekdayMask,
    required this.hour,
    required this.minute,
  });

  final int id;
  final bool enabled;

  /// bit0=月 … bit6=日。0 は単発。
  final int weekdayMask;
  final int hour;
  final int minute;

  bool get isOneShot => weekdayMask == 0;

  /// [weekday] は DateTime.monday(1)〜DateTime.sunday(7)。
  bool repeatsOn(int weekday) => (weekdayMask >> (weekday - 1)) & 1 == 1;

  Slot copyWith({
    int? id,
    bool? enabled,
    int? weekdayMask,
    int? hour,
    int? minute,
  }) => Slot(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    weekdayMask: weekdayMask ?? this.weekdayMask,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
  );

  void validate() {
    _check(id >= 0 && id < maxSlots, 'id は 0〜${maxSlots - 1}: $id');
    _check(
      weekdayMask >= 0 && weekdayMask <= 0x7F,
      'weekday_mask は 0〜127: $weekdayMask',
    );
    _check(hour >= 0 && hour <= 23, 'hour は 0〜23: $hour');
    _check(minute >= 0 && minute <= 59, 'minute は 0〜59: $minute');
  }

  Uint8List encode() {
    validate();
    final data = ByteData(slotSize)
      ..setUint8(0, id)
      ..setUint8(1, enabled ? 1 : 0)
      ..setUint8(2, weekdayMask)
      ..setUint8(3, hour)
      ..setUint8(4, minute);
    return data.buffer.asUint8List();
  }

  static Slot decode(List<int> bytes) {
    _check(bytes.length == slotSize, 'Slot は $slotSize bytes: ${bytes.length}');
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    _check(data.getUint8(1) <= 1, 'enabled は 0 / 1');
    final slot = Slot(
      id: data.getUint8(0),
      enabled: data.getUint8(1) == 1,
      weekdayMask: data.getUint8(2),
      hour: data.getUint8(3),
      minute: data.getUint8(4),
    );
    slot.validate();
    return slot;
  }

  @override
  bool operator ==(Object other) =>
      other is Slot &&
      other.id == id &&
      other.enabled == enabled &&
      other.weekdayMask == weekdayMask &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(id, enabled, weekdayMask, hour, minute);
}

/// Status characteristic（13 bytes）。
class DeviceStatus {
  const DeviceStatus({
    required this.valveOn,
    required this.remainingSeconds,
    required this.timeSynced,
    required this.nowEpoch,
    this.activeSlot = noActiveSlot,
  });

  static const unknown = DeviceStatus(
    valveOn: false,
    remainingSeconds: 0,
    timeSynced: false,
    nowEpoch: 0,
  );

  final bool valveOn;
  final int remainingSeconds;
  final bool timeSynced;
  final int nowEpoch;

  /// 予約で ON になっているスロットの id。手動 ON か OFF のときは [noActiveSlot]。
  final int activeSlot;

  Uint8List encode() {
    final data = ByteData(statusSize)
      ..setUint8(0, valveOn ? 1 : 0)
      ..setUint16(1, remainingSeconds, Endian.little)
      ..setUint8(3, timeSynced ? 1 : 0)
      ..setInt64(4, nowEpoch, Endian.little)
      ..setUint8(12, activeSlot);
    return data.buffer.asUint8List();
  }

  static DeviceStatus decode(List<int> bytes) {
    _check(
      bytes.length == statusSize,
      'Status は $statusSize bytes: ${bytes.length}',
    );
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    _check(data.getUint8(0) <= 1 && data.getUint8(3) <= 1, 'フラグは 0 / 1');
    return DeviceStatus(
      valveOn: data.getUint8(0) == 1,
      remainingSeconds: data.getUint16(1, Endian.little),
      timeSynced: data.getUint8(3) == 1,
      nowEpoch: data.getInt64(4, Endian.little),
      activeSlot: data.getUint8(12),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceStatus &&
      other.valveOn == valveOn &&
      other.remainingSeconds == remainingSeconds &&
      other.timeSynced == timeSynced &&
      other.nowEpoch == nowEpoch &&
      other.activeSlot == activeSlot;

  @override
  int get hashCode =>
      Object.hash(valveOn, remainingSeconds, timeSynced, nowEpoch, activeSlot);
}

/// Schedules characteristic: `count: u8` + Slot × count。
List<Slot> decodeSchedules(List<int> bytes) {
  _check(bytes.isNotEmpty, 'Schedules が空');
  final count = bytes[0];
  _check(count <= maxSlots, 'count は 0〜$maxSlots: $count');
  _check(
    bytes.length == 1 + slotSize * count,
    'Schedules の長さが不正: ${bytes.length} (count=$count)',
  );
  return [
    for (var i = 0; i < count; i++)
      Slot.decode(bytes.sublist(1 + i * slotSize, 1 + (i + 1) * slotSize)),
  ];
}

Uint8List encodeSchedules(List<Slot> slots) {
  _check(slots.length <= maxSlots, 'スロットは最大 $maxSlots 件');
  return Uint8List.fromList([
    slots.length,
    for (final slot in slots) ...slot.encode(),
  ]);
}
