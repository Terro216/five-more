import 'ui_helpers.dart';

import 'package:five_more/app/theme.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ValueNotifier<bool>> showChallenge(
    WidgetTester tester, {
    ChallengeKind kind = ChallengeKind.memory,
    ChallengeDifficulty difficulty = ChallengeDifficulty.easy,
    bool accessibleNavigation = false,
    double width = 390,
    double height = 844,
    double textScale = 1,
    VoidCallback? onComplete,
    VoidCallback? onEmergencyExit,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigation = ValueNotifier(accessibleNavigation);
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: navigation,
          builder: (context, accessible, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              accessibleNavigation: accessible,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
        ),
        home: ChallengeScreen(
          kind: kind,
          difficulty: difficulty,
          practice: onEmergencyExit == null,
          onComplete: onComplete ?? () {},
          onEmergencyExit: onEmergencyExit,
        ),
      ),
    );
    return navigation;
  }

  Future<void> tapVisible(WidgetTester tester, Finder control) async {
    await tester.ensureVisible(control);
    await tester.pumpAndSettle();
    await tester.tap(control);
    await tester.pump();
  }

  testWidgets('ordinary memory preview still ends after five seconds', (
    tester,
  ) async {
    await showChallenge(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Повтори рисунок'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accessible memory previews wait for the manual action', (
    tester,
  ) async {
    await showChallenge(tester, accessibleNavigation: true);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tapVisible(tester, find.text('Запомнил, начнём'));
    expect(find.text('Повтори рисунок'), findsOneWidget);
    await tapVisible(tester, find.text('Посмотреть ещё раз'));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tapVisible(tester, find.text('Запомнил, начнём'));
    expect(find.text('Повтори рисунок'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accessibility changes cancel and restart a pending preview', (
    tester,
  ) async {
    final navigation = await showChallenge(tester);
    await tester.pump(const Duration(seconds: 2));
    navigation.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Запомни рисунок'), findsOneWidget);
    navigation.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Запомни рисунок'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Повтори рисунок'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final difficulty in [
    ChallengeDifficulty.hard,
    ChallengeDifficulty.extreme,
  ]) {
    testWidgets(
      '${difficulty.name} memory reveals the entire pattern before starting the timer',
      (tester) async {
        await showChallenge(
          tester,
          difficulty: difficulty,
          width: 320,
          height: 640,
          textScale: 1.5,
          onEmergencyExit: () {},
        );
        final preview = find.byKey(const ValueKey('complete-memory-preview'));
        final bounds = tester.getRect(preview);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(
          bounds.bottom,
          lessThanOrEqualTo(
            tester.getRect(find.text('Не получается пройти')).top,
          ),
        );
        final cells = find.descendant(
          of: preview,
          matching: find.byType(DecoratedBox),
        );
        expect(
          cells,
          findsNWidgets(difficulty == ChallengeDifficulty.hard ? 25 : 36),
        );
        for (final element in cells.evaluate()) {
          final cell = tester.getRect(find.byWidget(element.widget));
          expect(bounds.contains(cell.center), isTrue);
        }
        await tester.pump(
          Duration(
            milliseconds: difficulty == ChallengeDifficulty.hard ? 2500 : 1800,
          ),
        );
        expect(preview, findsNothing);
        expect(find.text('Повтори рисунок'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final difficulty in ChallengeDifficulty.values) {
    testWidgets(
      '${difficulty.name} math fits doubled text and keeps emergency reachable',
      (tester) async {
        var completions = 0;
        var exits = 0;
        await showChallenge(
          tester,
          kind: ChallengeKind.math,
          difficulty: difficulty,
          width: 320,
          height: 640,
          textScale: 2,
          onComplete: () => completions += 1,
          onEmergencyExit: () => exits += 1,
        );
        final emergency = find.text('Не получается пройти');
        for (var step = 0; step < difficulty.index + 2; step += 1) {
          final expressionFinder = find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                RegExp(r'^\(?\d+ [ +−×÷] \d+').hasMatch(widget.data ?? ''),
          );
          final expression = tester.widget<Text>(expressionFinder).data!;
          await tester.ensureVisible(expressionFinder);
          await tester.pumpAndSettle();
          expect(expressionFinder.hitTestable(), findsOneWidget);
          if (difficulty.index >= 2) {
            final input = find.byKey(const ValueKey('math-answer-input'));
            await tester.ensureVisible(input);
            await tester.enterText(input, '${evaluateMath(expression)}');
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pump(const Duration(milliseconds: 500));
            expect(emergency.hitTestable(), findsOneWidget);
            continue;
          }
          final answers = find.byType(FilledButton);
          expect(answers, findsNWidgets(4));
          for (var index = 0; index < 4; index += 1) {
            final answer = answers.at(index);
            await tester.ensureVisible(answer);
            await tester.pumpAndSettle();
            expect(answer.hitTestable(), findsOneWidget);
            final size = tester.getSize(answer);
            expect(size.width, greaterThanOrEqualTo(48));
            expect(size.height, greaterThanOrEqualTo(48));
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: answer, matching: find.byType(RichText)),
            );
            expect(
              paragraph.getMaxIntrinsicHeight(paragraph.size.width),
              lessThanOrEqualTo(paragraph.size.height + 0.01),
              reason: 'The complete answer must fit without vertical clipping.',
            );
            expect(emergency.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          final correct = find.widgetWithText(
            FilledButton,
            '${_calculateExpression(expression)}',
          );
          await tapVisible(tester, correct);
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(completions, 1);
        expect(exits, 0);
        expect(emergency.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

int _calculateExpression(String expression) => evaluateMath(expression);
