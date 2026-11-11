import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'ui/home_page.dart';
import 'ui/scan_page.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ProviderScope(child: WakeariApp()));
}

class WakeariApp extends StatelessWidget {
  const WakeariApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'wakeari',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(light?.primary, Brightness.light),
        darkTheme: buildTheme(dark?.primary, Brightness.dark),
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const _Root(),
      ),
    );
  }
}

/// 接続状態に応じて スキャン → ホーム を切り替える。
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected =
        ref.watch(connectionProvider.select((c) => c.phase)) == Phase.connected;
    // 切断されたら、開いている設定・デバッグ画面などを閉じてスキャンに戻る。
    ref.listen(connectionProvider.select((c) => c.phase), (_, phase) {
      if (phase != Phase.connected) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    return AnimatedSwitcher(
      duration: Motion.medium,
      switchInCurve: Motion.spring,
      child: connected ? const HomePage() : const ScanPage(),
    );
  }
}
