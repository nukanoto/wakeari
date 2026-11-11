import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/protocol.dart';
import '../state/providers.dart';

/// [action] を実行し、失敗したら SnackBar で知らせる。成功したら true。
Future<bool> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    return true;
  } catch (e) {
    debugPrint('guarded action failed: $e');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(friendlyError(e, '送信に失敗しました'))));
    return false;
  }
}

/// コマンドを送り、失敗したら SnackBar で知らせる。成功したら true。
Future<bool> sendCommand(
  BuildContext context,
  WidgetRef ref,
  Command command,
) =>
    guarded(context, () => ref.read(connectionProvider.notifier).send(command));

/// 例外の生テキストは見せず、利用者向けの日本語にする。詳細はログのみ。
String friendlyError(Object e, String fallback) {
  if (e is StateError) return '$fallback。接続を確認してください';
  if (e is ProtocolException) return '$fallback。デバイスの応答が正しくありません';
  return '$fallback。もう一度お試しください';
}
