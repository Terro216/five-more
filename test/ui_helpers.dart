import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:five_more/widgets/emergency_stop.dart';

Future<void> enterEmergencyCode(WidgetTester tester) async {
  final code = tester
      .widget<Text>(find.byKey(const ValueKey('emergency-code')))
      .data!
      .replaceAll(' ', '');
  final input = find.byKey(const ValueKey('emergency-code-input'));
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  await tester.enterText(input, code);
  await tester.pumpAndSettle();
}

Future<void> completeEmergencyHold(WidgetTester tester) async {
  await enterEmergencyCode(tester);
  final hold = find.byKey(const ValueKey('emergency-hold'));
  await tester.ensureVisible(hold);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(tester.getCenter(hold));
  await tester.pump(const Duration(seconds: emergencyHoldSeconds));
  await gesture.up();
  await tester.pumpAndSettle();
}

int evaluateMath(String expression) {
  final grouped = RegExp(r'^\((\d+) × (\d+)\) − \((\d+) × (\d+)\)$')
      .firstMatch(expression);
  if (grouped != null) {
    return int.parse(grouped[1]!) * int.parse(grouped[2]!) -
        int.parse(grouped[3]!) * int.parse(grouped[4]!);
  }
  final tokens = expression.split(' ');
  final a = int.parse(tokens[0]), b = int.parse(tokens[2]);
  final subtotal = switch (tokens[1]) {
    '+' => a + b,
    '−' => a - b,
    '×' => a * b,
    '÷' => a ~/ b,
    _ => throw StateError('Unexpected expression'),
  };
  return tokens.length == 3
      ? subtotal
      : tokens[3] == '+'
      ? subtotal + int.parse(tokens[4])
      : subtotal - int.parse(tokens[4]);
}
