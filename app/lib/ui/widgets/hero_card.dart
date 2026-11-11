import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/protocol.dart';
import '../../state/next_run.dart';
import '../../state/providers.dart';
import '../format.dart';
import '../send.dart';
import '../theme.dart';
import 'shapes.dart';

/// 次の予約（待機中）または動作中の表示。
class HeroCard extends ConsumerWidget {
  const HeroCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(statusProvider);
    final slots = ref.watch(schedulesProvider);
    final now = ref.watch(deviceClockProvider).value ?? DateTime.now();
    final scheme = Theme.of(context).colorScheme;
    final next = nextRun(slots, now);

    return Container(
      clipBehavior: Clip.antiAlias,
      width: double.infinity,
      height: heroHeight,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -44,
            bottom: -56,
            child: ValveShape(
              on: status.valveOn,
              color: scheme.primary.withValues(alpha: 0.14),
              size: 190,
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 20, 0),
              child: AnimatedSwitcher(
                duration: Motion.short,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: status.valveOn
                    ? _Running(
                        key: const ValueKey('running'),
                        status: status,
                        slots: slots,
                        next: next,
                      )
                    : _Idle(
                        key: ValueKey(next == null ? 'none' : 'next'),
                        next: next,
                        now: now,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ヒーローの固定の高さ。状態が変わっても変えない。
const double heroHeight = 188;

class _Idle extends StatelessWidget {
  const _Idle({super.key, required this.next, required this.now});

  final NextRun? next;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onPrimaryContainer;
    final next = this.next;

    if (next == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '予約はありません',
          style: theme.textTheme.headlineMedium?.copyWith(color: on),
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '次の予約 · ${untilLabel(next.at, now)}',
          style: theme.textTheme.titleSmall?.copyWith(color: on),
        ),
        Text(
          formatTime(next.at.hour, next.at.minute),
          style: theme.textTheme.displayLarge?.copyWith(
            color: on,
            fontSize: 88,
            height: 1.1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          dayLabel(next.at, now),
          style: theme.textTheme.titleMedium?.copyWith(color: on),
        ),
      ],
    );
  }
}

class _Running extends ConsumerWidget {
  const _Running({
    super.key,
    required this.status,
    required this.slots,
    required this.next,
  });

  final DeviceStatus status;
  final List<Slot> slots;
  final NextRun? next;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = scheme.onPrimaryContainer;
    final active = slots.where((s) => s.id == status.activeSlot).firstOrNull;
    final next = this.next;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          active == null
              ? '手動'
              : '${formatTime(active.hour, active.minute)} の予約',
          style: theme.textTheme.titleSmall?.copyWith(color: on),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '動作中',
                style: theme.textTheme.displayMedium?.copyWith(color: on),
              ),
            ),
            FilledButton(
              onPressed: () => sendCommand(context, ref, const CommandOff()),
              child: const Text('停止'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          next == null ? '次の予約はありません' : '次は ${timeWithWeekday(next.at)}',
          style: theme.textTheme.titleMedium?.copyWith(color: on),
        ),
      ],
    );
  }
}
