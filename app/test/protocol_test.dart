import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeari/ble/protocol.dart';

void main() {
  group('TimeSync', () {
    test('byte-exact: epoch と tz=540', () {
      final bytes = const TimeSync(
        epochSeconds: 0x0102030405060708,
        tzOffsetMinutes: 540,
      ).encode();
      expect(bytes, [8, 7, 6, 5, 4, 3, 2, 1, 0x1C, 0x02]);
    });

    test('round-trip（負の tz を含む）', () {
      for (final t in [
        const TimeSync(epochSeconds: 1700000000, tzOffsetMinutes: 540),
        const TimeSync(epochSeconds: 1700000000, tzOffsetMinutes: -300),
      ]) {
        expect(TimeSync.decode(t.encode()), t);
      }
    });

    test('fromDateTime は UTC 秒とオフセットを使う', () {
      final now = DateTime.now();
      final t = TimeSync.fromDateTime(now);
      expect(t.epochSeconds, now.millisecondsSinceEpoch ~/ 1000);
      expect(t.tzOffsetMinutes, now.timeZoneOffset.inMinutes);
    });

    test('不正な長さ', () {
      expect(
        () => TimeSync.decode(List.filled(9, 0)),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('Command', () {
    test('ON はペイロードなし = [0x01]', () {
      expect(const CommandOn().encode(), [0x01]);
    });

    test('OFF / CLEAR / DELETE', () {
      expect(const CommandOff().encode(), [0x02]);
      expect(const CommandClear().encode(), [0x12]);
      expect(const CommandDelete(5).encode(), [0x11, 5]);
    });

    test('PUT は opcode + Slot 5 bytes', () {
      const slot = Slot(
        id: 2,
        enabled: true,
        weekdayMask: 0x1F,
        hour: 6,
        minute: 30,
      );
      expect(const CommandPut(slot).encode(), [0x10, 2, 1, 0x1F, 6, 30]);
    });

    test('decode は encode の逆', () {
      const commands = <Command>[
        CommandOn(),
        CommandOff(),
        CommandPut(
          Slot(id: 7, enabled: false, weekdayMask: 0, hour: 23, minute: 59),
        ),
        CommandDelete(0),
        CommandClear(),
      ];
      for (final c in commands) {
        expect(Command.decode(c.encode()), c);
      }
    });

    test('範囲外の id は encode 不可', () {
      expect(
        () => const CommandDelete(8).encode(),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('未知の opcode・不正な長さ・空は decode 不可', () {
      expect(() => Command.decode([0x7F]), throwsA(isA<ProtocolException>()));
      expect(
        () => Command.decode([0x01, 0x1E, 0x00]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Command.decode([0x02, 0x00]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Command.decode([0x10, 1, 2]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Command.decode([0x10, 1, 1, 0, 0, 0, 0]),
        throwsA(isA<ProtocolException>()),
      );
      expect(() => Command.decode(const []), throwsA(isA<ProtocolException>()));
    });
  });

  group('Slot', () {
    const slot = Slot(
      id: 3,
      enabled: true,
      weekdayMask: 0x41,
      hour: 7,
      minute: 5,
    );

    test('byte-exact 5 bytes', () {
      expect(slot.encode(), [3, 1, 0x41, 7, 5]);
      expect(slot.encode().length, slotSize);
    });

    test('round-trip', () {
      expect(Slot.decode(slot.encode()), slot);
    });

    test('曜日判定: bit0=月, bit6=日', () {
      expect(slot.repeatsOn(DateTime.monday), isTrue);
      expect(slot.repeatsOn(DateTime.sunday), isTrue);
      expect(slot.repeatsOn(DateTime.tuesday), isFalse);
      expect(slot.isOneShot, isFalse);
      expect(slot.copyWith(weekdayMask: 0).isOneShot, isTrue);
    });

    test('範囲外は encode / decode 不可', () {
      for (final bad in [
        slot.copyWith(id: 8),
        slot.copyWith(weekdayMask: 0x80),
        slot.copyWith(hour: 24),
        slot.copyWith(minute: 60),
      ]) {
        expect(() => bad.encode(), throwsA(isA<ProtocolException>()));
      }
      expect(
        () => Slot.decode([0, 2, 0, 0, 0]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Slot.decode([0, 1, 0, 0]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => Slot.decode([0, 1, 0, 0, 0, 0, 0]),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('Config', () {
    test('byte-exact: 30s = [0x1E, 0x00]、3600s = [0x10, 0x0E]', () {
      expect(encodeConfig(30), [0x1E, 0x00]);
      expect(encodeConfig(3600), [0x10, 0x0E]);
    });

    test('round-trip（境界 1 と 3600）', () {
      for (final v in [1, 30, 3600]) {
        expect(decodeConfig(encodeConfig(v)), v);
      }
    });

    test('範囲外・不正な長さ', () {
      expect(() => encodeConfig(0), throwsA(isA<ProtocolException>()));
      expect(() => encodeConfig(3601), throwsA(isA<ProtocolException>()));
      expect(() => decodeConfig([0, 0]), throwsA(isA<ProtocolException>()));
      expect(
        () => decodeConfig([0x11, 0x0E]),
        throwsA(isA<ProtocolException>()),
      );
      expect(() => decodeConfig([30]), throwsA(isA<ProtocolException>()));
      expect(() => decodeConfig([30, 0, 0]), throwsA(isA<ProtocolException>()));
    });
  });

  group('DeviceStatus', () {
    test('byte-exact パース（13 bytes, active_slot あり）', () {
      final bytes = Uint8List.fromList([
        1, // valve_on
        0x2A, 0x00, // remaining_s = 42
        1, // time_synced
        0x00,
        0x65,
        0xCD,
        0x1D,
        0x00,
        0x00,
        0x00,
        0x00, // 0x1DCD6500 = 500000000
        3, // active_slot
      ]);
      final s = DeviceStatus.decode(bytes);
      expect(s.valveOn, isTrue);
      expect(s.remainingSeconds, 42);
      expect(s.timeSynced, isTrue);
      expect(s.nowEpoch, 500000000);
      expect(s.activeSlot, 3);
      expect(s.encode(), bytes);
      expect(bytes.length, statusSize);
    });

    test('active_slot 0xFF は「なし」', () {
      final bytes = [0, 0, 0, 1, ...List.filled(8, 0), 0xFF];
      expect(DeviceStatus.decode(bytes).activeSlot, noActiveSlot);
    });

    test('未同期は now_epoch = 0、active_slot は none', () {
      final s = DeviceStatus.decode(DeviceStatus.unknown.encode());
      expect(s, DeviceStatus.unknown);
      expect(s.activeSlot, noActiveSlot);
    });

    test('不正な長さ・フラグ', () {
      expect(
        () => DeviceStatus.decode(List.filled(12, 0)),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => DeviceStatus.decode(List.filled(14, 0)),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => DeviceStatus.decode([2, ...List.filled(12, 0)]),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('Schedules', () {
    const a = Slot(id: 0, enabled: true, weekdayMask: 1, hour: 1, minute: 2);
    const b = Slot(id: 4, enabled: false, weekdayMask: 0, hour: 4, minute: 5);

    test('空は [0]', () {
      expect(encodeSchedules(const []), [0]);
      expect(decodeSchedules([0]), isEmpty);
    });

    test('round-trip と長さ', () {
      final bytes = encodeSchedules([a, b]);
      expect(bytes.length, 1 + 5 * 2);
      expect(bytes[0], 2);
      expect(decodeSchedules(bytes), [a, b]);
    });

    test('8 件で 41 bytes', () {
      final slots = [for (var i = 0; i < 8; i++) a.copyWith(id: i)];
      expect(encodeSchedules(slots).length, 41);
    });

    test('不正入力', () {
      expect(
        () => decodeSchedules(const []),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decodeSchedules([1, 0, 0]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decodeSchedules([9, ...List.filled(45, 0)]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => encodeSchedules([for (var i = 0; i < 9; i++) a]),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('Name', () {
    test('byte-exact と往復', () {
      expect(encodeName('wakeari'), [0x77, 0x61, 0x6b, 0x65, 0x61, 0x72, 0x69]);
      expect(decodeName(encodeName('wakeari-テスト')), 'wakeari-テスト');
    });

    test('前後の空白は取り除く', () {
      expect(decodeName(encodeName('  wakeari \n')), 'wakeari');
    });

    test('日本語は 9 文字（27 bytes）まで', () {
      expect(encodeName('あいうえおかきくけ').length, 27);
      expect(() => encodeName('あいうえおかきくけこ'), throwsA(isA<ProtocolException>()));
      expect(checkName('あいうえおかきくけこ'), NameIssue.tooLong);
    });

    test('ASCII は 29 bytes まで', () {
      expect(encodeName('a' * 29).length, 29);
      expect(() => encodeName('a' * 30), throwsA(isA<ProtocolException>()));
    });

    test('空・空白のみ・制御文字は拒否', () {
      expect(checkName(''), NameIssue.empty);
      expect(checkName('   '), NameIssue.empty);
      expect(checkName('a\u0000b'), NameIssue.controlChar);
      expect(checkName('a\tb'), NameIssue.controlChar);
      expect(checkName('a\u007fb'), NameIssue.controlChar);
      expect(() => encodeName(''), throwsA(isA<ProtocolException>()));
      expect(() => encodeName('a\u0001'), throwsA(isA<ProtocolException>()));
    });

    test('decode の不正入力', () {
      expect(() => decodeName(const []), throwsA(isA<ProtocolException>()));
      expect(
        () => decodeName(List.filled(30, 0x61)),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decodeName(const [0xff, 0xfe]),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decodeName(const [0x61, 0x00]),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
