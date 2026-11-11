import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 弾むようなモーションの共通カーブ・時間。
abstract final class Motion {
  static const Curve spring = Curves.easeOutBack;
  static const Curve springy = ElasticOutCurve(0.8);
  static const Duration medium = Duration(milliseconds: 450);
  static const Duration short = Duration(milliseconds: 280);
}

/// 角丸の共通値（Expressive は大きめ）。
abstract final class Radii {
  static const double card = 28;
  static const double sheet = 32;
  static const double hero = 40;
}

const Color _seed = Color(0xFF1A73E8);

/// [dynamicSeed] は端末の動的カラー（Material You）の primary。なければ固定シード。
ThemeData buildTheme(Color? dynamicSeed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: dynamicSeed ?? _seed,
    brightness: brightness,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme;

  RoundedRectangleBorder shape(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -2,
      ),
      displayMedium: text.displayMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.5,
      ),
      displaySmall: text.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      shape: shape(Radii.card),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontSize: 16),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      labelStyle: text.labelLarge,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: shape(Radii.card),
      extendedTextStyle: text.labelLarge?.copyWith(fontSize: 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
    ),
    dialogTheme: DialogThemeData(shape: shape(Radii.sheet)),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape(20),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// 設定・デバッグ画面の ListTile 共通スタイル（読みやすい文字サイズ）。
ListTileThemeData listTileTheme(ThemeData theme) => ListTileThemeData(
  titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
    color: theme.colorScheme.onSurface,
  ),
  minTileHeight: 64,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
);
