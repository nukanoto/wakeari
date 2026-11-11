import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/device_repository.dart';
import '../ble/protocol.dart';

final deviceRepositoryProvider = Provider<DeviceRepository>(
  (ref) => DeviceRepository(),
);

enum Phase { disconnected, connecting, connected }

class ConnectionState {
  const ConnectionState({
    this.phase = Phase.disconnected,
    this.error,
    this.deviceName,
    this.renaming = false,
  });

  final Phase phase;

  /// 接続中のデバイス名。
  final String? deviceName;

  /// 名前を変更して、デバイスの再起動・再接続を待っている。
  /// 想定どおりの切断なので、画面はスキャンに戻さない。
  final bool renaming;

  /// 直近の接続失敗・切断の理由（表示用）。
  final String? error;
}

/// 接続状態と、現在のセッションの所有者。
class ConnectionNotifier extends Notifier<ConnectionState> {
  DeviceSession? _session;
  StreamSubscription<BluetoothConnectionState>? _watch;

  @override
  ConnectionState build() {
    ref.onDispose(() {
      _watch?.cancel();
      _session?.close();
    });
    return const ConnectionState();
  }

  Future<DeviceSession> _open(BluetoothDevice device) => ref
      .read(deviceRepositoryProvider)
      .connect(
        device,
        onStatus: ref.read(statusProvider.notifier).set,
        onSchedules: ref.read(schedulesProvider.notifier).set,
        onConfig: ref.read(configProvider.notifier).set,
      );

  /// セッションを現在のものとして、切断の監視を始める。
  ConnectionState _attach(DeviceSession session) {
    _session = session;
    _watch = session.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && !state.renaming) {
        _teardown();
        state = const ConnectionState(error: '接続が切れました');
      }
    });
    final platform = session.device.platformName;
    return ConnectionState(
      phase: Phase.connected,
      deviceName: session.name ?? (platform.isEmpty ? 'wakeari' : platform),
    );
  }

  Future<void> connect(BluetoothDevice device) async {
    if (state.phase != Phase.disconnected) return;
    state = const ConnectionState(phase: Phase.connecting);
    try {
      state = _attach(await _open(device));
    } catch (e) {
      debugPrint('connect failed: $e');
      state = ConnectionState(error: '接続に失敗しました。もう一度お試しください');
    }
  }

  /// デバイス名を変更する。
  ///
  /// 書き込みに失敗したら例外を投げる（接続は保つ）。成功するとファームが
  /// リセットして切断されるので、その間は [ConnectionState.renaming] を立てて
  /// 画面をそのままにし、同じデバイスを再スキャンして再接続する。
  /// 再接続できたら true。時間内に戻らなければスキャン画面へ戻して false。
  Future<bool> renameDevice(String name) async {
    final session = _requireSession();
    final device = session.device;
    final newName = trimName(name);
    state = ConnectionState(
      phase: Phase.connected,
      deviceName: state.deviceName,
      renaming: true,
    );
    try {
      await session.writeName(newName);
    } catch (e) {
      state = ConnectionState(
        phase: Phase.connected,
        deviceName: state.deviceName,
      );
      if (!device.isConnected) {
        await _teardown();
        state = const ConnectionState(error: '接続が切れました');
      }
      rethrow;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    Duration remaining() => deadline.difference(DateTime.now());
    final repo = ref.read(deviceRepositoryProvider);
    try {
      // ファームがリセットして切断するのを待つ。リセット前に再スキャンすると
      // 古い名前のアドバタイズを拾ってしまう。
      try {
        await session.connectionState
            .firstWhere((s) => s == BluetoothConnectionState.disconnected)
            .timeout(const Duration(seconds: 6));
      } on TimeoutException {
        // 切断が見えなくても先へ進む。
      }
      await _watch?.cancel();
      _watch = null;
      _session = null;
      await session.close();
      // 再起動してアドバタイズを始めるまでの猶予。
      await Future<void>.delayed(const Duration(seconds: 1));

      final found = await repo.rediscover(
        device.remoteId,
        newName,
        timeout: remaining(),
      );
      if (!state.renaming) {
        // 待っている間に切断操作された。
        await found.disconnect();
        return false;
      }
      try {
        state = _attach(await _open(found).timeout(remaining()));
        return true;
      } on TimeoutException {
        await found.disconnect();
        rethrow;
      }
    } catch (e) {
      debugPrint('rename reconnect failed: $e');
      await _teardown();
      state = const ConnectionState(
        error: '名前は変更しましたが、再接続できませんでした。もう一度探してください',
      );
      return false;
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    state = const ConnectionState();
  }

  /// コマンドを送る。失敗時は例外を投げる。
  Future<void> send(Command command) => _requireSession().send(command);

  /// 時刻を今すぐ同期し直す。失敗時は例外を投げる。
  Future<void> syncTime() => _requireSession().syncTime();

  /// ON の長さ（秒）を書き込む。反映は Notify で [configProvider] に届く。
  Future<void> writeConfig(int durationSeconds) =>
      _requireSession().writeConfig(durationSeconds);

  DeviceSession _requireSession() {
    final session = _session;
    if (session == null || state.renaming) throw StateError('未接続です');
    return session;
  }

  Future<void> _teardown() async {
    await _watch?.cancel();
    _watch = null;
    final session = _session;
    _session = null;
    ref.read(statusProvider.notifier).set(DeviceStatus.unknown);
    ref.read(schedulesProvider.notifier).set(const []);
    ref.read(configProvider.notifier).set(null);
    await session?.close();
  }
}

final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
      ConnectionNotifier.new,
    );

class StatusNotifier extends Notifier<DeviceStatus> {
  @override
  DeviceStatus build() => DeviceStatus.unknown;

  void set(DeviceStatus value) => state = value;
}

final statusProvider = NotifierProvider<StatusNotifier, DeviceStatus>(
  StatusNotifier.new,
);

class SchedulesNotifier extends Notifier<List<Slot>> {
  @override
  List<Slot> build() => const [];

  void set(List<Slot> value) => state = value;
}

final schedulesProvider = NotifierProvider<SchedulesNotifier, List<Slot>>(
  SchedulesNotifier.new,
);

/// デバイスの Config（ON の長さ、秒）。未取得なら null。
class ConfigNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? value) => state = value;
}

final configProvider = NotifierProvider<ConfigNotifier, int?>(
  ConfigNotifier.new,
);

/// デバイスの現在時刻（ローカルタイム）を 1 秒ごとに流す。
///
/// Status は変化時にしか届かないので、受信時点の「デバイス時刻 − 端末時刻」を
/// 保持して端末の時計で進める。未同期なら端末の時刻をそのまま使う。
final deviceClockProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  final status = ref.watch(statusProvider);
  final skew = status.timeSynced && status.nowEpoch > 0
      ? Duration(
          milliseconds:
              status.nowEpoch * 1000 - DateTime.now().millisecondsSinceEpoch,
        )
      : Duration.zero;
  while (true) {
    yield DateTime.now().add(skew);
    await Future<void>.delayed(const Duration(seconds: 1));
  }
});

/// 空いている最小の id。満杯なら null。
int? smallestFreeId(List<Slot> slots) {
  final used = {for (final s in slots) s.id};
  for (var id = 0; id < maxSlots; id++) {
    if (!used.contains(id)) return id;
  }
  return null;
}

final scanResultsProvider = StreamProvider.autoDispose<List<ScanResult>>(
  (ref) => ref.watch(deviceRepositoryProvider).scanResults,
);

final isScanningProvider = StreamProvider.autoDispose<bool>(
  (ref) => ref.watch(deviceRepositoryProvider).isScanning,
);

final adapterStateProvider = StreamProvider.autoDispose<BluetoothAdapterState>(
  (ref) => ref.watch(deviceRepositoryProvider).adapterState,
);
