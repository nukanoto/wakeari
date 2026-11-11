import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakeari/ui/widgets/shapes.dart';

void main() {
  testWidgets('MorphingLoader は描画してもエラーにならない', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MorphingLoader())),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ValveShape は ON/OFF の切り替えでエラーにならない', (tester) async {
    Widget app(bool on) => MaterialApp(
      home: Scaffold(
        body: ValveShape(on: on, color: Colors.teal, child: const Text('x')),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
