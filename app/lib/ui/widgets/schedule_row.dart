import 'package:flutter/material.dart';

import '../../ble/protocol.dart';
import '../format.dart';

/// 予約 1 行。時刻・繰り返し・有効スイッチ。
class ScheduleRow extends StatelessWidget {
  const ScheduleRow({
    super.key,
    required this.slot,
    required this.onTap,
    required this.onToggle,
  });

  final Slot slot;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = slot.enabled;
    final muted = scheme.onSurfaceVariant.withValues(alpha: 0.6);

    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatTime(slot.hour, slot.minute),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: enabled ? scheme.onSurface : muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      repeatLabel(slot.weekdayMask),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: enabled ? scheme.onSurfaceVariant : muted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: onToggle),
            ],
          ),
        ),
      ),
    );
  }
}
