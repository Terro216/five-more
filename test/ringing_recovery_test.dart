import 'ui_helpers.dart';

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _longError =
    'Не удалось подтвердить действие системного будильника. '
    'Текущий звонок продолжает работать, а его настройки и число переносов '
    'сохранены. Проверь состояние телефона и повтори действие. '
    'Если необходимо срочно остановить звук, аварийное отключение остаётся '
    'доступным. Это длинное сообщение должно прокручиваться отдельно от кнопок.';

class _FailingAlarmGateway extends FakeAlarmGateway {
  bool rejectSnooze = false;
  bool rejectDismiss = false;
  final emergencyFlags = <bool>[];

  @override
  Future<AlarmResult> snooze(String id, {int? minutes}) async {
    if (rejectSnooze) {
      snoozeCalls.add(id);
      return const AlarmResult(ok: false, error: _longError);
    }
    return super.snooze(id);
  }

  @override
  Future<AlarmResult> dismiss(String id, {bool emergency = false}) async {
    emergencyFlags.add(emergency);
    if (rejectDismiss) {
      dismissCalls.add(id);
      return const AlarmResult(ok: false, error: _longError);
    }
    return super.dismiss(id, emergency: emergency);
  }
}

void main() {
  Future<AlarmController> showRinging(
    WidgetTester tester,
    _FailingAlarmGateway gateway,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const alarm = Alarm(
      id: 'recovery-alarm',
      hour: 7,
      minute: 30,
      challengeKind: ChallengeKind.math,
      difficulty: ChallengeDifficulty.easy,
      maxSnoozes: 3,
      snoozeMinutes: 5,
      escalateOnSnooze: false,
    );
    gateway.nativeAlarms[alarm.id] = alarm;
    gateway.ringing = RingingAlarm(
      alarm: alarm,
      occurrenceId: 'recovery-occurrence',
      firedAt: DateTime(2026, 10, 23, 7, 30),
      snoozesUsed: 0,
    );
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: fiveMoreTheme(),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 24),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
            textScaler: TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final ringing = controller.ringing;
            return ringing == null
                ? const Scaffold(body: Center(child: Text('Звонок завершён')))
                : RingingScreen(
                    key: ValueKey(ringing.occurrenceId),
                    controller: controller,
                    ringing: ringing,
                  );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Finder control(String key) => find.byKey(ValueKey(key));

  void expectControlsVisible(WidgetTester tester) {
    for (final key in [
      'ringing-start-challenge',
      'ringing-snooze',
      'ringing-emergency',
    ]) {
      final button = control(key);
      expect(button.hitTestable(), findsOneWidget, reason: key);
      final rect = tester.getRect(button);
      expect(rect.top, greaterThanOrEqualTo(24), reason: key);
      expect(rect.bottom, lessThanOrEqualTo(616), reason: key);
      expect(rect.height, greaterThanOrEqualTo(48), reason: key);
    }
  }

  Future<void> expectScrollableError(WidgetTester tester) async {
    final error = control('ringing-error');
    expect(tester.widget<Text>(error).data, _longError);
    final errorScroll = find.ancestor(
      of: error,
      matching: find.byType(SingleChildScrollView),
    );
    expect(errorScroll, findsOneWidget);
    expect(errorScroll.hitTestable(), findsOneWidget);
    final viewport = tester.getRect(errorScroll);
    expect(viewport.height, lessThanOrEqualTo(120));
    expect(viewport.top, greaterThanOrEqualTo(24));
    expect(viewport.bottom, lessThanOrEqualTo(616));
    final before = tester.getTopLeft(error).dy;
    await tester.drag(errorScroll, const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(error).dy, lessThan(before));
    expectControlsVisible(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> holdEmergency(WidgetTester tester) async {
    await tester.tap(control('ringing-emergency'));
    await tester.pumpAndSettle();
    await completeEmergencyHold(tester);
  }

  testWidgets('failed snooze keeps controls and long error usable at 2x text', (
    tester,
  ) async {
    final gateway = _FailingAlarmGateway()..rejectSnooze = true;
    final controller = await showRinging(tester, gateway);
    await tester.tap(control('ringing-snooze'));
    await tester.pumpAndSettle();
    expect(gateway.snoozeCalls, ['recovery-alarm']);
    expect(gateway.dismissCalls, isEmpty);
    expect(controller.ringing?.occurrenceId, 'recovery-occurrence');
    expect(controller.ringing?.snoozesUsed, 0);
    expect(gateway.ringing?.snoozesUsed, 0);
    expectControlsVisible(tester);
    await expectScrollableError(tester);

    gateway.rejectSnooze = false;
    await tester.tap(control('ringing-snooze'));
    await tester.pumpAndSettle();
    expect(gateway.snoozeCalls, ['recovery-alarm', 'recovery-alarm']);
    expect(controller.ringing, isNull);
    expect(find.byType(RingingScreen), findsNothing);
    expect(find.text('Звонок завершён'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('solved challenge retries failed dismissal without a new task', (
    tester,
  ) async {
    final gateway = _FailingAlarmGateway()..rejectDismiss = true;
    final controller = await showRinging(tester, gateway);
    await tester.tap(control('ringing-start-challenge'));
    await tester.pumpAndSettle();
    expect(find.byType(ChallengeScreen), findsOneWidget);
    expect(gateway.dismissCalls, isEmpty);
    expect(gateway.snoozeCalls, isEmpty);
    for (var step = 0; step < 2; step += 1) {
      final expression = tester
          .widget<Text>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  RegExp(r'^\d+ [ +−] \d+').hasMatch(widget.data ?? ''),
            ),
          )
          .data!;
      final tokens = expression.split(' ');
      final first = int.parse(tokens[0]);
      final second = int.parse(tokens[2]);
      final answer = tokens[1] == '+' ? first + second : first - second;
      final choice = find.widgetWithText(FilledButton, '$answer');
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      if (step == 0) expect(gateway.dismissCalls, isEmpty);
    }
    expect(gateway.dismissCalls, ['recovery-alarm']);
    expect(gateway.emergencyFlags, [false]);
    expect(controller.ringing?.occurrenceId, 'recovery-occurrence');
    expect(find.byType(ChallengeScreen), findsNothing);
    expect(find.text('Повторить отключение'), findsOneWidget);
    expectControlsVisible(tester);
    await expectScrollableError(tester);

    gateway.rejectDismiss = false;
    await tester.tap(control('ringing-start-challenge'));
    await tester.pumpAndSettle();
    expect(gateway.dismissCalls, ['recovery-alarm', 'recovery-alarm']);
    expect(gateway.emergencyFlags, [false, false]);
    expect(gateway.snoozeCalls, isEmpty);
    expect(controller.ringing, isNull);
    expect(find.byType(ChallengeScreen), findsNothing);
    expect(find.byType(RingingScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed emergency stop returns usable controls and can retry', (
    tester,
  ) async {
    final gateway = _FailingAlarmGateway()..rejectDismiss = true;
    final controller = await showRinging(tester, gateway);
    await holdEmergency(tester);
    expect(gateway.dismissCalls, ['recovery-alarm']);
    expect(gateway.emergencyFlags, [true]);
    expect(controller.ringing?.occurrenceId, 'recovery-occurrence');
    expect(find.text('Пройти задание'), findsOneWidget);
    expect(find.text('Повторить отключение'), findsNothing);
    expectControlsVisible(tester);
    await expectScrollableError(tester);

    gateway.rejectDismiss = false;
    await holdEmergency(tester);
    expect(gateway.dismissCalls, ['recovery-alarm', 'recovery-alarm']);
    expect(gateway.emergencyFlags, [true, true]);
    expect(controller.ringing, isNull);
    expect(find.byType(RingingScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
