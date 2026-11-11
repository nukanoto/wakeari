// 実機 ESP32-C5（wakeari ファーム, プロトコル v2）と実 iPhone の BLE 結合テスト。
//
// iOS のリリースビルドを `xcrun devicectl ... --console` で起動して実行するため、
// `print` は見えない。ログは dart:io の stdout に書いて flush する。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wakeari/ble/protocol.dart';
import 'package:wakeari/main.dart';
import 'package:wakeari/state/providers.dart';

Future<void> out(String m) async {
  stdout.writeln(m);
  await stdout.flush();
}

Future<void> log(String m) =>
    out('[e2e ${DateTime.now().toIso8601String()}] $m');

/// 本体を実行し、結果行を必ず出力する。
Future<void> reported(String tag, Future<void> Function() body) async {
  try {
    await body();
    await out('$tag RESULT: PASS');
  } catch (e, st) {
    await out('[${tag.toLowerCase()}] ERROR: $e');
    await out('$st');
    await out('$tag RESULT: FAIL ${e.toString().split('\n').first}');
    rethrow;
  }
}

const renamed = 'wakeari-テスト';

/// [names] のどれかをアドバタイズしているデバイスを探す（名前変更の途中失敗に備える）。
Future<BluetoothDevice> findDevice(
  ProviderContainer c, [
  Set<String> names = const {'wakeari', renamed},
]) async {
  final repo = c.read(deviceRepositoryProvider);
  final found = Completer<BluetoothDevice>();
  final sub = repo.scanResults.listen((rs) {
    for (final r in rs) {
      final name = r.advertisementData.advName.isNotEmpty
          ? r.advertisementData.advName
          : r.device.platformName;
      if (names.contains(name) && !found.isCompleted) found.complete(r.device);
    }
  });
  await repo.startScan();
  try {
    return await found.future.timeout(const Duration(seconds: 30));
  } finally {
    await sub.cancel();
  }
}

Future<T> waitFor<T>(
  T? Function() probe,
  String what, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final v = probe();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TestFailure('タイムアウト: $what');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  test('BLE end-to-end', timeout: const Timeout(Duration(minutes: 8)), () {
    return reported('E2E', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final statuses = <(DateTime, DeviceStatus)>[];
      c.listen(statusProvider, (_, s) => statuses.add((DateTime.now(), s)));
      c.listen(schedulesProvider, (_, s) {});
      c.listen(configProvider, (_, s) {});
      final conn = c.read(connectionProvider.notifier);
      DeviceStatus status() => c.read(statusProvider);
      List<Slot> slots() => c.read(schedulesProvider);
      int? config() => c.read(configProvider);

      BluetoothCharacteristic raw(BluetoothDevice d, String uuid) => d
          .servicesList
          .firstWhere((s) => s.uuid == Guid(serviceUuid))
          .characteristics
          .firstWhere((x) => x.uuid == Guid(uuid));

      Future<BluetoothDevice> connect() async {
        final dev = await findDevice(c);
        await log('found wakeari ${dev.remoteId}');
        await conn.connect(dev);
        expect(
          c.read(connectionProvider).phase,
          Phase.connected,
          reason: c.read(connectionProvider).error,
        );
        return dev;
      }

      // STEP1: 接続 + 時刻同期
      await log('STEP1 scan+connect+time sync');
      var dev = await connect();
      await waitFor(() => status().timeSynced ? true : null, 'time_synced');
      final skew =
          (status().nowEpoch - DateTime.now().millisecondsSinceEpoch ~/ 1000)
              .abs();
      await log('STEP1 synced nowEpoch=${status().nowEpoch} skew=${skew}s');
      expect(skew <= 5, true);
      await conn.syncTime();
      await log('STEP1 syncTime re-write ok');

      // STEP2: Config 読み出しと変更（Notify 確認）
      await log('STEP2 Config read/write');
      await waitFor(() => config(), 'config read');
      await log('STEP2 initial config=${config()}');
      await conn.writeConfig(3);
      await waitFor(() => config() == 3 ? true : null, 'config notify 3');
      await log('STEP2 config notify ok =3');

      // STEP3: CLEAR
      await log('STEP3 CLEAR');
      await conn.send(const CommandClear());
      await waitFor(() => slots().isEmpty ? true : null, 'schedules empty');

      // STEP4: ON（Config 3 秒で自動 OFF）
      await log('STEP4 ON (auto-off ~3s)');
      final n0 = statuses.length;
      await conn.send(const CommandOn());
      await waitFor(
        () => status().valveOn ? true : null,
        'valve_on',
        timeout: const Duration(milliseconds: 1500),
      );
      await log(
        'STEP4 on remaining=${status().remainingSeconds} active=${status().activeSlot}',
      );
      expect(status().remainingSeconds, inInclusiveRange(1, 3));
      expect(status().activeSlot, noActiveSlot);
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(statuses.length - n0 >= 2, true, reason: 'ON 中の Notify');
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(status().valveOn, false);
      await log('STEP4 auto off ok');

      // STEP5: ON してすぐ OFF
      await log('STEP5 ON then OFF');
      await conn.send(const CommandOn());
      await waitFor(() => status().valveOn ? true : null, 'valve_on 2');
      await conn.send(const CommandOff());
      await waitFor(
        () => !status().valveOn ? true : null,
        'valve off',
        timeout: const Duration(seconds: 2),
      );
      expect(status().remainingSeconds, 0);
      await log('STEP5 ok');

      // STEP6: 不正な生書き込みは拒否される
      await log('STEP6 invalid raw writes');
      final invalid = <(String, String, List<int>)>[
        ('config 0', configUuid, [0x00, 0x00]),
        ('PUT id 9', commandUuid, [0x10, 9, 1, 0x7F, 6, 30]),
        ('unknown opcode', commandUuid, [0x7F]),
      ];
      for (final (name, uuid, bytes) in invalid) {
        Object? err;
        try {
          await raw(dev, uuid).write(bytes);
        } catch (e) {
          err = e;
        }
        await log(
          'STEP6 $name -> ${err == null ? 'NO ERROR' : err.toString().split('\n').first}',
        );
        expect(err, isNotNull, reason: '$name should fail');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(status().valveOn, false);
      expect(slots(), isEmpty);
      expect(decodeConfig(await raw(dev, configUuid).read()), 3);
      expect(() => encodeConfig(0), throwsA(isA<ProtocolException>()));
      await log('STEP6 state unchanged ok');

      // STEP7: PUT / toggle / DELETE
      await log('STEP7 PUT/toggle/DELETE');
      const weekly = Slot(
        id: 0,
        enabled: true,
        weekdayMask: 0x7F,
        hour: 6,
        minute: 30,
      );
      const once = Slot(
        id: 3,
        enabled: true,
        weekdayMask: 0,
        hour: 22,
        minute: 5,
      );
      await conn.send(const CommandPut(weekly));
      await conn.send(const CommandPut(once));
      await waitFor(() => slots().length == 2 ? true : null, '2 slots');
      expect(slots(), [weekly, once]);
      await conn.send(CommandPut(weekly.copyWith(enabled: false)));
      await waitFor(
        () => slots().first.enabled ? null : true,
        'weekly disabled',
      );
      expect(slots(), [weekly.copyWith(enabled: false), once]);
      await conn.send(const CommandDelete(0));
      await waitFor(() => slots().length == 1 ? true : null, 'deleted');
      expect(slots(), [once]);
      await log('STEP7 ok');

      // STEP8: 単発を次の分に発火させる
      await log('STEP8 one-shot firing');
      await conn.send(const CommandClear());
      await waitFor(() => slots().isEmpty ? true : null, 'cleared');
      final now = DateTime.now();
      var target = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute + 1,
      );
      if (target.difference(now).inSeconds < 15) {
        target = target.add(const Duration(minutes: 1));
      }
      final shot = Slot(
        id: 1,
        enabled: true,
        weekdayMask: 0,
        hour: target.hour,
        minute: target.minute,
      );
      await conn.send(CommandPut(shot));
      await waitFor(() => slots().length == 1 ? true : null, 'one-shot put');
      await log('STEP8 scheduled for $target');
      await waitFor(
        () => status().valveOn ? true : null,
        'one-shot fire',
        timeout:
            target.difference(DateTime.now()) + const Duration(seconds: 20),
      );
      await log(
        'STEP8 fired at ${DateTime.now()} active=${status().activeSlot}',
      );
      expect(status().activeSlot, shot.id);
      await waitFor(
        () => !status().valveOn ? true : null,
        'one-shot off',
        timeout: const Duration(seconds: 8),
      );
      await waitFor(
        () => slots().length == 1 && !slots().first.enabled ? true : null,
        'slot disabled',
        timeout: const Duration(seconds: 5),
      );
      expect(slots().first, shot.copyWith(enabled: false));
      await log('STEP8 ok: off, slot disabled');

      // STEP9: 再接続後も Slot と Config が残る
      await log('STEP9 reconnect persistence');
      await conn.send(
        const CommandPut(
          Slot(id: 0, enabled: true, weekdayMask: 0x7F, hour: 7, minute: 0),
        ),
      );
      await waitFor(() => slots().length == 2 ? true : null, '2 slots');
      await conn.writeConfig(7);
      await waitFor(() => config() == 7 ? true : null, 'config 7');
      final expected = List<Slot>.of(slots());
      await conn.disconnect();
      expect(c.read(connectionProvider).phase, Phase.disconnected);
      await Future<void>.delayed(const Duration(seconds: 2));
      dev = await connect();
      await waitFor(
        () => slots().length == 2 ? true : null,
        'slots after reconnect',
      );
      expect(slots(), expected);
      await waitFor(
        () => config() == 7 ? true : null,
        'config after reconnect',
      );
      await log('STEP9 persisted slots=$expected config=${config()}');

      // STEP10: 名前変更（不正値の拒否 → 変更 → 自動再接続 → 広告名の確認 → 元に戻す）
      await log('STEP10 change device name');
      await waitFor(() => c.read(connectionProvider).deviceName, 'device name');
      Object? nameErr;
      try {
        await raw(dev, nameUuid).write(List.filled(30, 0x61));
      } catch (e) {
        nameErr = e;
      }
      await log(
        'STEP10 30-byte name -> ${nameErr == null ? 'NO ERROR' : nameErr.toString().split('\n').first}',
      );
      expect(nameErr, isNotNull, reason: '30 bytes name should fail');
      expect(c.read(connectionProvider).phase, Phase.connected);
      expect(decodeName(await raw(dev, nameUuid).read()), 'wakeari');
      expect(() => encodeName('a' * 30), throwsA(isA<ProtocolException>()));

      Future<void> renameAndVerify(String name) async {
        final ok = await conn.renameDevice(name);
        await log('STEP10 rename -> "$name" reconnected=$ok');
        expect(ok, true, reason: c.read(connectionProvider).error);
        final st = c.read(connectionProvider);
        expect(st.phase, Phase.connected);
        expect(st.renaming, false);
        expect(st.deviceName, name);
        expect(decodeName(await raw(dev, nameUuid).read()), name);
        // 再接続後も時刻同期済みで、Slot / Config を読み直せている。
        await waitFor(() => status().timeSynced ? true : null, 'resynced');
        await waitFor(() => config(), 'config after rename');
        // 広告名（スキャン応答）も新しい名前になっている。
        await conn.disconnect();
        await Future<void>.delayed(const Duration(seconds: 2));
        final found = await findDevice(c, {name});
        await log('STEP10 advertised name matches "$name" (${found.remoteId})');
        await conn.connect(found);
        expect(
          c.read(connectionProvider).phase,
          Phase.connected,
          reason: c.read(connectionProvider).error,
        );
        expect(c.read(connectionProvider).deviceName, name);
      }

      await renameAndVerify(renamed);
      await renameAndVerify('wakeari');
      await log('STEP10 ok: name restored to wakeari');

      // 後始末: Config を 30 に戻し、アラームを全削除
      await conn.writeConfig(defaultDurationSeconds);
      await waitFor(
        () => config() == defaultDurationSeconds ? true : null,
        'config restore',
      );
      await conn.send(const CommandClear());
      await waitFor(() => slots().isEmpty ? true : null, 'final clear');
      await conn.disconnect();
      await log('CLEANUP config=30, cleared, disconnected');
    });
  });

  testWidgets(
    'app smoke: scan -> connect -> home -> settings -> disconnect',
    (tester) {
      return reported('SMOKE', () async {
        await tester.pumpWidget(const ProviderScope(child: WakeariApp()));
        Future<void> until(Finder f, Duration timeout) async {
          final end = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 200));
            if (f.evaluate().isNotEmpty) return;
          }
          throw TestFailure('見つからない: $f');
        }

        await Future<void>.delayed(const Duration(seconds: 3));
        final tile = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(InkWell),
            )
            .first;
        await until(tile, const Duration(seconds: 30));
        await tester.tap(tile);
        final heroLabel = find.textContaining(RegExp('次のアラーム|アラームはありません|動作中'));
        await until(heroLabel, const Duration(seconds: 30));
        await log('SMOKE home screen shown');
        await tester.tap(find.byTooltip('設定'));
        await until(find.text('切断'), const Duration(seconds: 5));
        await log('SMOKE settings shown');
        await tester.tap(find.text('切断'));
        await until(find.text('もう一度探す'), const Duration(seconds: 10));
        await log('SMOKE disconnected, back to scan');
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
