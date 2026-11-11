import 'package:flutter/cupertino.dart'
    show
        CupertinoDatePicker,
        CupertinoDatePickerMode,
        CupertinoTheme,
        CupertinoThemeData,
        CupertinoTextThemeData;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/protocol.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../send.dart';
import '../theme.dart';

/// 予約の追加・編集シートを開く。[existing] があれば編集（id を維持）。
Future<void> showScheduleEditor(BuildContext context, {Slot? existing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ScheduleEditor(existing: existing),
  );
}

class ScheduleEditor extends ConsumerStatefulWidget {
  const ScheduleEditor({super.key, this.existing});

  final Slot? existing;

  @override
  ConsumerState<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditor> {
  late TimeOfDay _time;
  late int _mask;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _time = s == null
        ? TimeOfDay.now()
        : TimeOfDay(hour: s.hour, minute: s.minute);
    _mask = s?.weekdayMask ?? 0;
  }

  /// [command] を送り、成功したらシートを閉じる。
  Future<void> _submit(Command? command) async {
    if (command == null) return;
    setState(() => _busy = true);
    final ok = await sendCommand(context, ref, command);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  Command? _saveCommand() {
    final existing = widget.existing;
    final id = existing?.id ?? smallestFreeId(ref.read(schedulesProvider));
    if (id == null) return null;
    return CommandPut(
      Slot(
        id: id,
        enabled: existing?.enabled ?? true,
        weekdayMask: _mask,
        hour: _time.hour,
        minute: _time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final existing = widget.existing;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 176,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              clipBehavior: Clip.antiAlias,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: theme.brightness,
                  primaryColor: scheme.primary,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  itemExtent: 52,
                  initialDateTime: DateTime(
                    2000,
                    1,
                    1,
                    _time.hour,
                    _time.minute,
                  ),
                  onDateTimeChanged: (d) =>
                      _time = TimeOfDay(hour: d.hour, minute: d.minute),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('繰り返し', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < 7; i++)
                  _DayCircle(
                    label: weekdayLabels[i],
                    selected: (_mask >> i) & 1 == 1,
                    onTap: () => setState(() => _mask ^= 1 << i),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '曜日を選ばないと1回のみ',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                if (existing != null) ...[
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _submit(CommandDelete(existing.id)),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.error,
                      minimumSize: const Size(64, 56),
                    ),
                    child: const Text('削除'),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : () => _submit(_saveCommand()),
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCircle extends StatelessWidget {
  const _DayCircle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.short,
          curve: Motion.spring,
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? scheme.primary : scheme.surfaceContainerHigh,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
