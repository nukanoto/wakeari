import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/providers.dart';
import 'debug_page.dart';
import 'widgets/name_dialog.dart';
import 'format.dart';
import 'send.dart';
import 'theme.dart';

final _versionProvider = FutureProvider<String>(
  (ref) async => (await PackageInfo.fromPlatform()).version,
);

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = theme.textTheme.bodyLarge?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final name = ref.watch(connectionProvider.select((c) => c.deviceName));
    final renaming = ref.watch(connectionProvider.select((c) => c.renaming));
    final status = ref.watch(statusProvider);
    final clock = ref.watch(deviceClockProvider).value;
    final version = ref.watch(_versionProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListTileTheme(
        data: listTileTheme(theme),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const _Header('デバイス'),
            ListTile(
              title: const Text('名前'),
              subtitle: renaming ? const Text('名前を変更しています…') : null,
              trailing: renaming
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name ?? '-',
                            style: value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
              onTap: renaming || name == null
                  ? null
                  : () => _rename(context, ref, name),
            ),
            ListTile(
              title: const Text('接続'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 10, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text('接続中', style: value),
                ],
              ),
            ),
            ListTile(
              title: const Text('デバイスの時刻'),
              trailing: Text(
                status.timeSynced && clock != null ? formatClock(clock) : '未同期',
                style: value?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            ListTile(
              title: const Text('タイムゾーン'),
              trailing: Text(
                formatUtcOffset(DateTime.now().timeZoneOffset),
                style: value,
              ),
            ),
            ListTile(
              title: const Text('今すぐ時刻を同期'),
              trailing: const Icon(Icons.refresh),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final ok = await guarded(
                  context,
                  ref.read(connectionProvider.notifier).syncTime,
                );
                if (ok) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('時刻を同期しました')));
                }
              },
            ),
            const _Header('その他'),
            ListTile(
              title: const Text('デバッグ'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DebugPage()),
              ),
            ),
            ListTile(
              title: const Text('切断'),
              onTap: () => ref.read(connectionProvider.notifier).disconnect(),
            ),
            ListTile(
              title: const Text('バージョン'),
              trailing: Text(version ?? '', style: value),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _rename(
  BuildContext context,
  WidgetRef ref,
  String current,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final next = await showNameDialog(context, current);
  if (next == null || next == current) return;
  try {
    final ok = await ref.read(connectionProvider.notifier).renameDevice(next);
    if (ok) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('名前を変更しました')));
    }
  } catch (e) {
    debugPrint('rename failed: $e');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(friendlyError(e, '名前を変更できませんでした'))),
      );
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
