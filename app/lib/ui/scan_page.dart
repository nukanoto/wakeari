import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'theme.dart';
import 'widgets/shapes.dart';

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  String? _scanError;

  /// 接続操作をしたデバイス（ボタンに進捗を出す）。
  DeviceIdentifier? _connectingId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  Future<void> _startScan() async {
    setState(() => _scanError = null);
    try {
      await ref.read(deviceRepositoryProvider).startScan();
    } catch (e) {
      debugPrint('startScan failed: $e');
      if (mounted) {
        setState(
          () => _scanError = e is StateError
              ? 'Bluetooth がオンになっていません'
              : 'デバイスを探せませんでした。もう一度お試しください',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final scanning = ref.watch(isScanningProvider).value ?? false;
    final results = ref.watch(scanResultsProvider).value ?? const [];
    final adapter = ref.watch(adapterStateProvider).value;
    final connecting = connection.phase == Phase.connecting;
    final bluetoothOff =
        adapter != null &&
        adapter != BluetoothAdapterState.on &&
        adapter != BluetoothAdapterState.unknown;
    final message = _scanError ?? connection.error;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Text('wakeari', style: theme.textTheme.displayMedium),
              const SizedBox(height: 4),
              Text(
                '近くのデバイスを探しています',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              if (message != null) _Notice(text: message),
              if (bluetoothOff) const _Notice(text: 'Bluetooth をオンにしてください'),
              Expanded(
                child: results.isEmpty
                    ? Center(
                        child: scanning || connecting
                            ? const MorphingLoader(size: 120)
                            : const Text('デバイスが見つかりませんでした'),
                      )
                    : ListView(
                        children: [
                          for (final r in results)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _DeviceTile(
                                result: r,
                                connecting:
                                    connecting &&
                                    _connectingId == r.device.remoteId,
                                enabled: !connecting,
                                onTap: () {
                                  setState(
                                    () => _connectingId = r.device.remoteId,
                                  );
                                  ref
                                      .read(connectionProvider.notifier)
                                      .connect(r.device);
                                },
                              ),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: scanning || connecting ? null : _startScan,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: Text(connecting ? '接続中…' : 'もう一度探す'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.result,
    required this.connecting,
    required this.enabled,
    required this.onTap,
  });

  final ScanResult result;

  /// このデバイスへ接続中（ボタンに進捗を表示）。
  final bool connecting;

  /// 他のデバイスに接続中でない（ボタンを押せる）。
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : result.device.platformName.isNotEmpty
        ? result.device.platformName
        : 'wakeari';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.bluetooth, color: theme.colorScheme.primary, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleLarge),
                    Text(
                      '${result.device.remoteId}  ·  ${result.rssi} dBm',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              FilledButton.tonal(
                onPressed: enabled ? onTap : null,
                style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                child: connecting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('接続'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
