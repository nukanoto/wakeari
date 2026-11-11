import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart';

final Guid _service = Guid(serviceUuid);

/// 接続済みデバイスとの 1 回分のセッション。
class DeviceSession {
  DeviceSession._(
    this.device,
    this._time,
    this._command,
    this._config,
    this._name,
    this.name,
    this._subscriptions,
  );

  final BluetoothDevice device;
  final BluetoothCharacteristic _time;
  final BluetoothCharacteristic _command;
  final BluetoothCharacteristic _config;
  final BluetoothCharacteristic _name;

  /// 接続時に Name characteristic から読んだデバイス名。読めなければ null。
  final String? name;
  final List<StreamSubscription<dynamic>> _subscriptions;

  /// 接続状態の変化。切断を検知するのに使う。
  Stream<BluetoothConnectionState> get connectionState =>
      device.connectionState;

  Future<void> send(Command command) => _command.write(command.encode());

  /// 現在の時刻とタイムゾーンをデバイスに書き込む。
  Future<void> syncTime() =>
      _time.write(TimeSync.fromDateTime(DateTime.now()).encode());

  /// 1 回の ON の長さ（秒）をデバイスに保存する。
  Future<void> writeConfig(int durationSeconds) =>
      _config.write(encodeConfig(durationSeconds));

  /// デバイス名を書き込む。成功するとファームが約 500ms 後にリセットして切断される。
  Future<void> writeName(String name) => _name.write(encodeName(name));

  Future<void> close() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await device.disconnect();
  }
}

class DeviceRepository {
  /// アドバタイズされた Service UUID で絞り込んでスキャンする。
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  /// アダプタが ON になるのを待ってからスキャンを始める。
  ///
  /// iOS では起動直後の数秒間、CBCentralManager が PoweredOn になっていない。
  /// その間に startScan を呼ぶと失敗するので待つ。
  Future<void> startScan() async {
    await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw StateError('Bluetooth がオンになっていません'),
        );
    await FlutterBluePlus.startScan(
      withServices: [_service],
      timeout: const Duration(seconds: 15),
    );
  }

  /// 名前変更後のデバイスを探す。
  ///
  /// remoteId が一致するものを優先し、見つからない状態が続くときだけ
  /// Service UUID でスキャンして見つかった、新しい名前と一致するものを使う。
  Future<BluetoothDevice> rediscover(
    DeviceIdentifier id,
    String name, {
    required Duration timeout,
  }) async {
    final end = DateTime.now().add(timeout);
    final byId = Completer<BluetoothDevice>();
    final byName = <BluetoothDevice>[];
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId == id && !byId.isCompleted) {
          byId.complete(r.device);
        }
        final advName = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (advName == name && !byName.contains(r.device)) {
          byName.add(r.device);
        }
      }
    });
    try {
      final since = DateTime.now();
      while (DateTime.now().isBefore(end)) {
        if (!FlutterBluePlus.isScanningNow) {
          try {
            await startScan();
          } catch (_) {
            // アダプタが復帰するまで待って再試行する。
          }
        }
        final device = byId.isCompleted
            ? await byId.future
            : (byName.isNotEmpty &&
                      DateTime.now().difference(since) >
                          const Duration(seconds: 5)
                  ? byName.first
                  : null);
        if (device != null) return device;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw TimeoutException('デバイスが見つかりません', timeout);
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// 接続し、Characteristic を解決して時刻を同期し、Notify を購読する。
  ///
  /// [onStatus] / [onSchedules] / [onConfig] には接続直後の Read 値と以降の Notify 値が渡る。
  Future<DeviceSession> connect(
    BluetoothDevice device, {
    required void Function(DeviceStatus) onStatus,
    required void Function(List<Slot>) onSchedules,
    required void Function(int) onConfig,
  }) async {
    await FlutterBluePlus.stopScan();
    await device.connect(license: License.nonprofit);
    try {
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == _service,
        orElse: () => throw ProtocolException('wakeari のサービスが見つかりません'),
      );
      BluetoothCharacteristic find(String uuid) =>
          service.characteristics.firstWhere(
            (c) => c.uuid == Guid(uuid),
            orElse: () =>
                throw ProtocolException('Characteristic が見つかりません: $uuid'),
          );

      final time = find(timeUuid);
      final statusChar = find(statusUuid);
      final schedulesChar = find(schedulesUuid);
      final configChar = find(configUuid);
      final command = find(commandUuid);
      final nameChar = find(nameUuid);

      // 接続直後に必ず時刻を書き込む。
      await time.write(TimeSync.fromDateTime(DateTime.now()).encode());

      // 不正なペイロードは無視する（仕様上ファームは正しい値のみ送る）。
      void deliver<T>(
        List<int> bytes,
        T Function(List<int>) decode,
        void Function(T) sink,
      ) {
        try {
          sink(decode(bytes));
        } on ProtocolException {
          return;
        }
      }

      final subscriptions = <StreamSubscription<dynamic>>[
        statusChar.onValueReceived.listen(
          (bytes) => deliver(bytes, DeviceStatus.decode, onStatus),
        ),
        schedulesChar.onValueReceived.listen(
          (bytes) => deliver(bytes, decodeSchedules, onSchedules),
        ),
        configChar.onValueReceived.listen(
          (bytes) => deliver(bytes, decodeConfig, onConfig),
        ),
      ];
      await statusChar.setNotifyValue(true);
      await schedulesChar.setNotifyValue(true);
      await configChar.setNotifyValue(true);

      // 時刻同期後の値を初期値として読む。
      deliver(await statusChar.read(), DeviceStatus.decode, onStatus);
      deliver(await schedulesChar.read(), decodeSchedules, onSchedules);
      deliver(await configChar.read(), decodeConfig, onConfig);

      String? name;
      try {
        name = decodeName(await nameChar.read());
      } catch (_) {
        name = null;
      }

      return DeviceSession._(
        device,
        time,
        command,
        configChar,
        nameChar,
        name,
        subscriptions,
      );
    } catch (_) {
      await device.disconnect();
      rethrow;
    }
  }
}
