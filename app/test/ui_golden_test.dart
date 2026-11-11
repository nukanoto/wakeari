import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakeari/ble/protocol.dart';
import 'package:wakeari/state/providers.dart';
import 'package:wakeari/ui/debug_page.dart';
import 'package:wakeari/ui/home_page.dart';
import 'package:wakeari/ui/settings_page.dart';
import 'package:wakeari/ui/theme.dart';
import 'package:wakeari/ui/widgets/hero_card.dart';

// 2026-11-12 (木) 05:00
final _now = DateTime(2026, 11, 12, 5, 0);

class _Status extends StatusNotifier {
  _Status(this.initial);
  final DeviceStatus initial;
  @override
  DeviceStatus build() => initial;
}

class _Schedules extends SchedulesNotifier {
  _Schedules(this.initial);
  final List<Slot> initial;
  @override
  List<Slot> build() => initial;
}

class _Connection extends ConnectionNotifier {
  @override
  ConnectionState build() =>
      const ConnectionState(phase: Phase.connected, deviceName: 'wakeari-01');
}

class _Config extends ConfigNotifier {
  @override
  int? build() => 30;
}

DeviceStatus _status({bool on = false, int active = noActiveSlot}) =>
    DeviceStatus(
      valveOn: on,
      remainingSeconds: on ? 20 : 0,
      timeSynced: true,
      nowEpoch: _now.millisecondsSinceEpoch ~/ 1000,
      activeSlot: active,
    );

const _s0 = Slot(id: 0, enabled: true, weekdayMask: 0x1F, hour: 6, minute: 30);
const _s1 = Slot(id: 1, enabled: false, weekdayMask: 0x60, hour: 8, minute: 0);
const _s2 = Slot(id: 2, enabled: true, weekdayMask: 0, hour: 18, minute: 45);
const _s3 = Slot(id: 3, enabled: true, weekdayMask: 0x7F, hour: 22, minute: 0);

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());

  final icons = FontLoader('MaterialIcons')
    ..addFont(read('$fonts/MaterialIcons-Regular.otf'));
  await icons.load();

  // 日本語が描ける Noto Sans CJK JP があればそれを Roboto として使う。
  final home = Platform.environment['HOME'] ?? '';
  final noto = [
    for (final w in ['Regular', 'Medium', 'Bold', 'Black'])
      '$home/Library/Fonts/NotoSansCJKjp-$w.otf',
  ];
  final files = noto.every((p) => File(p).existsSync())
      ? noto
      : [
          for (final w in ['Regular', 'Medium', 'Bold', 'Black'])
            '$fonts/Roboto-$w.ttf',
        ];
  // Cupertino のピッカーや等幅表示が使うフォント名にも同じフォントを当てる。
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    '.SF Pro Text',
    '.SF Pro Display',
    'Menlo',
  ]) {
    final loader = FontLoader(family);
    for (final p in files) {
      loader.addFont(read(p));
    }
    await loader.load();
  }
}

ProviderContainer _container({
  DeviceStatus? status,
  List<Slot> slots = const [],
}) {
  return ProviderContainer(
    overrides: [
      statusProvider.overrideWith(() => _Status(status ?? _status())),
      schedulesProvider.overrideWith(() => _Schedules(slots)),
      connectionProvider.overrideWith(_Connection.new),
      configProvider.overrideWith(_Config.new),
      deviceClockProvider.overrideWith((ref) => Stream.value(_now)),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget home, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(393, 852) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(null, Brightness.light),
        darkTheme: buildTheme(null, Brightness.dark),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        home: home,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
    PackageInfo.setMockInitialValues(
      appName: 'wakeari',
      packageName: 'app.wakeari',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<void> golden(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );

  testWidgets('home: 1 schedule', (tester) async {
    await _pump(tester, _container(slots: [_s0]), const HomePage());
    await golden(tester, 'home_1');
    expect(find.text('無効'), findsNothing);
    expect(find.text('予約'), findsOneWidget);
  });

  testWidgets('home: 4 schedules', (tester) async {
    await _pump(
      tester,
      _container(slots: [_s0, _s1, _s2, _s3]),
      const HomePage(),
    );
    await golden(tester, 'home_4');
    expect(find.textContaining('無効'), findsNothing);
    // 区切り線は行の間だけ（4 行 → 3 本）。
    expect(find.byType(Divider), findsNWidgets(3));
  });

  testWidgets('home: 1 schedule has no divider', (tester) async {
    await _pump(tester, _container(slots: [_s0]), const HomePage());
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('home: no schedules', (tester) async {
    await _pump(tester, _container(), const HomePage());
    await golden(tester, 'home_empty');
  });

  testWidgets('home: running', (tester) async {
    await _pump(
      tester,
      _container(status: _status(on: true, active: 0), slots: [_s0, _s2]),
      const HomePage(),
    );
    await golden(tester, 'home_running');
  });

  testWidgets('home: dark idle 4 schedules', (tester) async {
    await _pump(
      tester,
      _container(slots: [_s0, _s1, _s2, _s3]),
      const HomePage(),
      brightness: Brightness.dark,
    );
    await golden(tester, 'home_4_dark');
  });

  testWidgets('home: dark running', (tester) async {
    await _pump(
      tester,
      _container(status: _status(on: true, active: 0), slots: [_s0]),
      const HomePage(),
      brightness: Brightness.dark,
    );
    await golden(tester, 'home_running_dark');
  });

  testWidgets('hero height is constant across states', (tester) async {
    final container = _container();
    await _pump(tester, container, const HomePage());
    Size hero() => tester.getSize(find.byType(HeroCard));
    final sizes = <Size>[hero()];

    Future<void> step() async {
      await tester.pump();
      await _settle(tester);
      sizes.add(hero());
    }

    // 予約なし → 予約あり（有効）
    container.read(schedulesProvider.notifier).set([_s0]);
    await step();
    // 無効に切り替え
    container.read(schedulesProvider.notifier).set([
      _s0.copyWith(enabled: false),
    ]);
    await step();
    // 再び有効
    container.read(schedulesProvider.notifier).set([_s0]);
    await step();
    // 動作中
    container.read(statusProvider.notifier).set(_status(on: true, active: 0));
    await step();
    // 動作中・次の予約なし
    container.read(schedulesProvider.notifier).set(const []);
    await step();
    // 手動で動作中でないとき
    container.read(statusProvider.notifier).set(_status());
    await step();

    expect(sizes.toSet().length, 1, reason: '$sizes');
    expect(sizes.first.height, heroHeight);
  });

  testWidgets('editor sheet with time selection', (tester) async {
    await _pump(tester, _container(slots: [_s0, _s2]), const HomePage());
    await tester.tap(find.text('18:45'));
    await _settle(tester);
    await golden(tester, 'editor');
    expect(find.text('保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor sheet dark', (tester) async {
    await _pump(
      tester,
      _container(slots: [_s0, _s2]),
      const HomePage(),
      brightness: Brightness.dark,
    );
    await tester.tap(find.text('18:45'));
    await _settle(tester);
    await golden(tester, 'editor_dark');
  });

  testWidgets('settings page', (tester) async {
    await _pump(tester, _container(slots: [_s0]), const SettingsPage());
    await _settle(tester);
    await golden(tester, 'settings');
  });

  testWidgets('name edit dialog', (tester) async {
    await _pump(tester, _container(slots: [_s0]), const SettingsPage());
    await _settle(tester);
    await tester.tap(find.text('名前'));
    await _settle(tester);
    await golden(tester, 'name_dialog');
    expect(find.text('キャンセル'), findsOneWidget);
    expect(find.text('あと 19 バイト（全角は 3 バイト）'), findsOneWidget);

    // 日本語 10 文字（30 bytes）は 1 バイト超過。
    await tester.enterText(find.byType(TextField), 'あいうえおかきくけこ');
    await tester.pump();
    await _settle(tester);
    await golden(tester, 'name_dialog_error');
    expect(find.textContaining('1 バイト多すぎます'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '変更'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'あいうえおかきくけ');
    await tester.pump();
    expect(find.text('あと 2 バイト（全角は 3 バイト）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('debug page', (tester) async {
    await _pump(tester, _container(slots: [_s0, _s2]), const DebugPage());
    await _settle(tester);
    await golden(tester, 'debug');
  });
}
