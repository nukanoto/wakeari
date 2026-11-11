import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ble/protocol.dart';

/// 名前の編集ダイアログ。変更するなら正規化済みの名前を、キャンセルなら null を返す。
Future<String?> showNameDialog(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (_) => NameDialog(current: current),
    );

class NameDialog extends StatefulWidget {
  const NameDialog({super.key, required this.current});

  final String current;

  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.current.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _used => utf8.encode(trimName(_controller.text)).length;

  String? get _error => switch (checkName(_controller.text)) {
    NameIssue.empty => '名前を入力してください',
    NameIssue.tooLong => '${_used - nameMaxBytes} バイト多すぎます。短くしてください',
    NameIssue.controlChar => '使えない文字が含まれています',
    null => null,
  };

  void _submit() {
    if (_error == null) Navigator.of(context).pop(trimName(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: const Text('名前を変更'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'デバイスの名前',
          errorText: error,
          errorMaxLines: 2,
          helperText:
              'あと ${nameMaxBytes - _used < 0 ? 0 : nameMaxBytes - _used} '
              'バイト（全角は 3 バイト）',
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: error == null ? _submit : null,
          child: const Text('変更'),
        ),
      ],
    );
  }
}
