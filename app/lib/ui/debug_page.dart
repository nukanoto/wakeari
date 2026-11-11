import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/protocol.dart';
import '../state/providers.dart';
import 'format.dart';
import 'send.dart';
import 'theme.dart';

class DebugPage extends ConsumerWidget {
  const DebugPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = ref.watch(statusProvider);
    final slots = ref.watch(schedulesProvider);
    final duration = ref.watch(configProvider);

    Future<bool> setDuration(int seconds) => guarded(
      context,
      () => ref
          .read(connectionProvider.notifier)
          .writeConfig(seconds.clamp(minDurationSeconds, maxDurationSeconds)),
    );

    final raw = [
      'valve_on:    ${status.valveOn}',
      'remaining:   ${status.remainingSeconds}',
      'synced:      ${status.timeSynced}',
      'epoch:       ${status.nowEpoch}',
      'active_slot: ${status.activeSlot == noActiveSlot ? '0xFF' : status.activeSlot}',
      'slots:       ${slots.length}/$maxSlots',
      'config:      ${duration ?? '-'} s',
    ].join('\n');

    return Scaffold(
      appBar: AppBar(title: const Text('デバッグ')),
      body: ListTileTheme(
        data: listTileTheme(theme),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const _Header('動作の設定（デバイスに保存）'),
            ListTile(
              title: const Text('ONにする時間'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton.filledTonal(
                    tooltip: '1秒減らす',
                    icon: const Icon(Icons.remove),
                    onPressed: duration == null
                        ? null
                        : () => setDuration(duration - 1),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: duration == null
                        ? null
                        : () async {
                            final v = await _askSeconds(context, duration);
                            if (v != null) await setDuration(v);
                          },
                    child: Container(
                      width: 84,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        duration == null ? '-' : formatSeconds(duration),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: '1秒増やす',
                    icon: const Icon(Icons.add),
                    onPressed: duration == null
                        ? null
                        : () => setDuration(duration + 1),
                  ),
                ],
              ),
            ),
            ListTile(
              title: const Text('初期値に戻す（$defaultDurationSeconds秒）'),
              onTap: () => setDuration(defaultDurationSeconds),
            ),
            const _Header('手動テスト'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          sendCommand(context, ref, const CommandOn()),
                      child: const Text('ON'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () =>
                          sendCommand(context, ref, const CommandOff()),
                      child: const Text('OFF'),
                    ),
                  ),
                ],
              ),
            ),
            const _Header('状態（生データ）'),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(16),
              width: double.infinity,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                raw,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontFamily: 'Menlo',
                  height: 1.5,
                ),
              ),
            ),
            const _Header('危険な操作'),
            ListTile(
              title: Text(
                'アラームをすべて削除',
                style: theme.textTheme.bodyLarge?.copyWith(color: scheme.error),
              ),
              onTap: () => _confirmClear(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<int?> _askSeconds(BuildContext context, int current) {
    final controller = TextEditingController(text: '$current');
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ONにする時間（秒）'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            helperText: '$minDurationSeconds〜$maxDurationSeconds',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('設定'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アラームをすべて削除しますか？'),
        content: const Text('この操作は元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await sendCommand(context, ref, const CommandClear());
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
