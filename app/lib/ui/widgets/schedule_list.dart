import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/protocol.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../send.dart';
import 'schedule_editor.dart';
import 'schedule_row.dart';

/// 予約一覧（全幅の行を細い区切り線で並べる）。
/// スワイプで削除（元に戻せる）、Switch で有効/無効、タップで編集。
class ScheduleList extends ConsumerStatefulWidget {
  const ScheduleList({super.key});

  @override
  ConsumerState<ScheduleList> createState() => _ScheduleListState();
}

class _ScheduleListState extends ConsumerState<ScheduleList> {
  /// 削除コマンド送信済みで、デバイスの Notify を待っている id。
  final Set<int> _deleting = {};

  Future<bool> _delete(Slot slot) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await sendCommand(context, ref, CommandDelete(slot.id));
    if (!ok) return false;
    _deleting.add(slot.id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${formatTime(slot.hour, slot.minute)} の予約を削除しました'),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () => ref
                .read(connectionProvider.notifier)
                .send(CommandPut(slot))
                .catchError((Object _) {}),
          ),
        ),
      );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<Slot>>(schedulesProvider, (_, next) {
      final ids = {for (final s in next) s.id};
      setState(() => _deleting.removeWhere((id) => !ids.contains(id)));
    });
    final slots = ref
        .watch(schedulesProvider)
        .where((s) => !_deleting.contains(s.id))
        .toList();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Text(
        '予約',
        style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary),
      ),
    );

    if (slots.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                '予約はまだありません',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        for (final (i, slot) in slots.indexed) ...[
          if (i > 0)
            Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          Dismissible(
            key: ValueKey('slot-${slot.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              color: scheme.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Text(
                    '削除',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            confirmDismiss: (_) => _delete(slot),
            onDismissed: (_) => setState(() {}),
            child: ScheduleRow(
              slot: slot,
              onTap: () => showScheduleEditor(context, existing: slot),
              onToggle: (v) => sendCommand(
                context,
                ref,
                CommandPut(slot.copyWith(enabled: v)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
