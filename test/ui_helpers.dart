import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> completeEmergencyHold(WidgetTester tester) async {
  final acknowledgement = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(acknowledgement);
  await tester.pumpAndSettle();
  expect(acknowledgement.hitTestable(), findsOneWidget);
  await tester.tap(acknowledgement);
  await tester.pumpAndSettle();
  final hold = find.text('Удерживай 5 секунд');
  await tester.ensureVisible(hold);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(tester.getCenter(hold));
  await tester.pump(const Duration(seconds: 5));
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
