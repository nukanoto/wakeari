import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/protocol.dart';
import '../state/providers.dart';
import 'settings_page.dart';
import 'widgets/hero_card.dart';
import 'widgets/schedule_editor.dart';
import 'widgets/schedule_list.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final full =
        ref.watch(schedulesProvider.select((s) => s.length)) >= maxSlots;
    final name =
        ref.watch(connectionProvider.select((c) => c.deviceName)) ?? 'wakeari';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 24,
        title: Row(
          children: [
            Flexible(
              child: Text(
                name,
                style: theme.textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.circle, size: 8, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              '接続中',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '設定',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 112),
        children: const [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: HeroCard(),
          ),
          ScheduleList(),
        ],
      ),
      floatingActionButton: full
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showScheduleEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('予約を追加'),
            ),
    );
  }
}
