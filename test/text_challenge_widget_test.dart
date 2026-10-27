import 'ui_helpers.dart';

import 'package:five_more/app/theme.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

final _answer = find.byKey(const ValueKey('typed-challenge-answer'));
final _submit = find.byKey(const ValueKey('typed-challenge-submit'));

String _shownAnswer(WidgetTester tester, ChallengeKind kind) {
  if (kind == ChallengeKind.mirror) {
    return tester
        .widget<Text>(find.byKey(const ValueKey('mirror-phrase')))
        .data!;
  }
  return tester
      .widgetList<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'captcha-glyph-',
              ),
        ),
      )
      .map((widget) => widget.data!)
      .join();
}

Future<ValueNotifier<double>> _mount(
  WidgetTester tester, {
  required ChallengeKind kind,
  ChallengeDifficulty difficulty = ChallengeDifficulty.easy,
  double width = 390,
  double height = 844,
  double textScale = 1,
  double keyboardHeight = 0,
  bool accessibleNavigation = false,
  VoidCallback? onComplete,
  VoidCallback? onEmergencyExit,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scale = ValueNotifier(textScale);
  addTearDown(scale.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: fiveMoreTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: scale,
        builder: (context, currentScale, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 24),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
            textScaler: TextScaler.linear(currentScale),
            accessibleNavigation: accessibleNavigation,
          ),
          child: child!,
        ),
      ),
      home: ChallengeScreen(
        kind: kind,
        difficulty: difficulty,
        onComplete: onComplete ?? () {},
        onEmergencyExit: onEmergencyExit,
        practice: onEmergencyExit == null,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return scale;
}

Future<void> _typeAndSubmit(WidgetTester tester, String value) async {
  await tester.ensureVisible(_answer);
  await tester.pumpAndSettle();
  await tester.enterText(_answer, value);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  for (final kind in [ChallengeKind.mirror, ChallengeKind.captcha]) {
    testWidgets(
      '${kind.name} accepts visible submit taps above the keyboard at 2x text',
      (tester) async {
        var completions = 0;
        await _mount(
          tester,
          kind: kind,
          width: 320,
          height: 640,
          textScale: 2,
          keyboardHeight: 260,
          onComplete: () => completions += 1,
          onEmergencyExit: () {},
        );
        for (var round = 0; round < 2; round++) {
          final answer = _shownAnswer(tester, kind);
          await tester.ensureVisible(_answer);
          await tester.pumpAndSettle();
          await tester.enterText(_answer, answer);
          await tester.ensureVisible(_submit);
          await tester.pumpAndSettle();
          expect(_submit.hitTestable(), findsOneWidget);
          expect(tester.getRect(_submit).bottom, lessThanOrEqualTo(380));
          expect(
            find.text('Не получается пройти').hitTestable(),
            findsOneWidget,
          );
          await tester.tap(_submit);
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(completions, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${kind.name} rolls back one stage on error and survives rebuild',
      (tester) async {
        var completions = 0;
        final scale = await _mount(
          tester,
          kind: kind,
          onComplete: () => completions += 1,
        );
        final first = _shownAnswer(tester, kind);
        if (kind == ChallengeKind.mirror) {
          final reflection = tester.widget<Transform>(
            find.byKey(const ValueKey('mirror-reflection')),
          );
          expect(reflection.transform.entry(0, 0), -1);
          expect(reflection.transform.entry(1, 1), 1);
        }
        final field = tester.widget<TextField>(_answer);
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
        expect(field.autofillHints, isEmpty);
        await _typeAndSubmit(tester, 'WRONG');
        final retry = _shownAnswer(tester, kind);
        expect(retry, isNot(first));
        expect(find.text('1 / 2'), findsOneWidget);
        expect(completions, 0);
        expect(find.text('Неверный ответ'), findsOneWidget);
        scale.value = 1.3;
        await tester.pumpAndSettle();
        expect(_shownAnswer(tester, kind), retry);
        expect(tester.widget<TextField>(_answer).controller!.text, isEmpty);
        await _typeAndSubmit(tester, retry.toUpperCase());
        // Duplicate IME submissions during the transition must not solve another step.
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('2 / 2'), findsOneWidget);
        final second = _shownAnswer(tester, kind);
        expect(second, isNot(retry));
        expect(tester.widget<TextField>(_answer).controller!.text, isEmpty);
        await _typeAndSubmit(tester, 'WRONG');
        expect(find.text('1 / 2'), findsOneWidget);
        for (var remaining = 0; remaining < 2; remaining++) {
          await _typeAndSubmit(
            tester,
            _shownAnswer(tester, kind).toLowerCase(),
          );
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(completions, 1);
        expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
        await tester.pump(const Duration(seconds: 1));
        expect(completions, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${kind.name} does not announce the hidden answer to a screenreader',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(tester, kind: kind, accessibleNavigation: true);
          final answer = _shownAnswer(tester, kind);
          expect(find.bySemanticsLabel(answer), findsNothing);
          if (kind == ChallengeKind.captcha) {
            for (final glyph in answer.split('').toSet()) {
              expect(find.bySemanticsLabel(RegExp('^$glyph\$')), findsNothing);
            }
          }
          expect(
            find.textContaining('Это визуальное задание.'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      '${kind.name} keeps emergency reachable above keyboard with doubled text',
      (tester) async {
        var completions = 0;
        var exits = 0;
        await _mount(
          tester,
          kind: kind,
          difficulty: ChallengeDifficulty.hard,
          width: 320,
          height: 640,
          textScale: 2,
          keyboardHeight: 260,
          onComplete: () => completions += 1,
          onEmergencyExit: () => exits += 1,
        );
        await tester.ensureVisible(_answer);
        await tester.pumpAndSettle();
        await tester.enterText(_answer, 'WRONG');
        await tester.pumpAndSettle();
        final emergency = find.text('Не получается пройти');
        expect(emergency.hitTestable(), findsOneWidget);
        expect(tester.getRect(emergency).bottom, lessThanOrEqualTo(380));
        expect(tester.takeException(), isNull);
        await tester.tap(emergency);
        await tester.pumpAndSettle();
        expect(exits, 0);
        await completeEmergencyHold(tester);
        expect(exits, 1);
        expect(completions, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
