import 'dart:ui' show Tristate;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/wake_preset.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

Future<void> _openEditor(
  WidgetTester tester,
  AlarmController controller, {
  Alarm? alarm,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: fiveMoreTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) =>
                    AlarmEditor(controller: controller, alarm: alarm),
              ),
            ),
            child: const Text('Открыть настройки'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Открыть настройки'));
  await tester.pumpAndSettle();
}

Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  double delta = 220,
}) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _preset(WakePreset value) =>
    find.byKey(ValueKey('preset-${value.name}'));
final _save = find.byKey(const ValueKey('save-alarm'));
final _advanced = find.byKey(const ValueKey('alarm-advanced'));

void main() {
  testWidgets(
    'creates an alarm from a preset without opening manual settings',
    (tester) async {
      final gateway = FakeAlarmGateway();
      final storage = MemoryAlarmStorage();
      final controller = AlarmController(gateway: gateway, storage: storage);
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      await _openEditor(tester, controller);

      await _tap(tester, _preset(WakePreset.direct));
      expect(find.byKey(const ValueKey('escalate-on-snooze')), findsNothing);
      expect(_save.hitTestable(), findsOneWidget);
      await tester.tap(_save);
      await tester.pumpAndSettle();

      final saved = storage.snapshot.alarms.single;
      expect(WakePreset.matching(saved), WakePreset.direct);
      expect(saved.timeLabel, '07:30');
      expect(saved.weekdays, [1, 2, 3, 4, 5]);
      expect(gateway.scheduleCalls, hasLength(1));
      expect(find.byType(AlarmEditor), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening and saving a custom alarm preserves its exact values', (
    tester,
  ) async {
    const custom = Alarm(
      id: 'custom-legacy',
      hour: 6,
      minute: 45,
      title: '  Свой подъём  ',
      weekdays: [2, 6],
      enabled: false,
      snoozeMinutes: 7,
      maxSnoozes: 2,
      challengeKind: ChallengeKind.sequence,
      difficulty: ChallengeDifficulty.hard,
      escalateOnSnooze: false,
    );
    final gateway = FakeAlarmGateway()..nativeAlarms[custom.id] = custom;
    final storage = MemoryAlarmStorage()
      ..snapshot = const AlarmSnapshot(alarms: [custom]);
    final controller = AlarmController(gateway: gateway, storage: storage);
    addTearDown(controller.dispose);
    await controller.initialize(startPolling: false);
    await _openEditor(tester, controller, alarm: custom);

    await _reveal(tester, find.byKey(const ValueKey('wake-preset-summary')));
    expect(find.byKey(const ValueKey('wake-preset-summary')), findsOneWidget);
    expect(
      tester
          .widget<ExpansionTile>(find.byKey(const ValueKey('alarm-advanced')))
          .initiallyExpanded,
      isTrue,
    );
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(gateway.scheduleCalls.single.toJson(), custom.toJson());
    expect(storage.snapshot.alarms.single.toJson(), custom.toJson());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an explicit preset change preserves identity and reopens selected',
    (tester) async {
      final initial = WakePreset.gentle.applyTo(
        const Alarm(
          id: 'weekend',
          hour: 10,
          minute: 20,
          title: 'Без спешки',
          weekdays: [6, 7],
        ),
      );
      final gateway = FakeAlarmGateway()..nativeAlarms[initial.id] = initial;
      final storage = MemoryAlarmStorage()
        ..snapshot = AlarmSnapshot(alarms: [initial]);
      final controller = AlarmController(gateway: gateway, storage: storage);
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await controller.initialize(startPolling: false);
        await _openEditor(tester, controller, alarm: initial);

        await _reveal(tester, _preset(WakePreset.gentle));
        expect(
          tester
              .getSemantics(_preset(WakePreset.gentle))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        await _tap(tester, _preset(WakePreset.gradual));
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(
          gateway.scheduleCalls.single.toJson(),
          WakePreset.gradual.applyTo(initial).toJson(),
        );

        await _openEditor(tester, controller, alarm: controller.alarms.single);
        await _reveal(tester, _preset(WakePreset.gradual));
        final selected = tester.getSemantics(_preset(WakePreset.gradual));
        expect(selected.flagsCollection.isSelected, Tristate.isTrue);
        expect(selected.flagsCollection.isButton, isTrue);
        await _reveal(tester, find.text('Выбрано: С разгоном'));
        expect(find.text('Выбрано: С разгоном'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('manual settings expose every challenge and update the summary', (
    tester,
  ) async {
    final gateway = FakeAlarmGateway();
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await controller.initialize(startPolling: false);
      await _openEditor(tester, controller);
      await _tap(tester, _advanced);

      for (final kind in ChallengeKind.values) {
        final choice = find.byKey(ValueKey('challenge-kind-${kind.name}'));
        await _tap(tester, choice);
        final selected = tester.getSemantics(choice);
        expect(selected.flagsCollection.isSelected, Tristate.isTrue);
        expect(selected.flagsCollection.isButton, isTrue);
      }
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Сложно'));
      final toggle = find.byKey(const ValueKey('escalate-on-snooze'));
      await _reveal(tester, toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await _tap(tester, find.byKey(const ValueKey('practice-alarm')));
      final practice = tester.widget<ChallengeScreen>(
        find.byType(ChallengeScreen),
      );
      expect(practice.kind, ChallengeKind.mixed);
      expect(practice.difficulty, ChallengeDifficulty.hard);
      expect(practice.practice, isTrue);
      Navigator.of(tester.element(find.byType(ChallengeScreen))).pop();
      await tester.pumpAndSettle();

      final title = find.byKey(const ValueKey('alarm-title'));
      await _reveal(tester, title);
      await tester.enterText(title, 'Мой режим');
      // Close the software keyboard before checking the collapsed summary.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _reveal(tester, _advanced, delta: -220);
      await tester.tap(find.text('Настроить вручную'));
      await tester.pumpAndSettle();
      await _reveal(
        tester,
        find.byKey(const ValueKey('wake-preset-summary')),
        delta: -220,
      );
      expect(find.byKey(const ValueKey('wake-preset-summary')), findsOneWidget);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(gateway.scheduleCalls.single.title, 'Мой режим');
      expect(gateway.scheduleCalls.single.challengeKind, ChallengeKind.mixed);
      expect(gateway.scheduleCalls.single.difficulty, ChallengeDifficulty.hard);
      expect(gateway.snoozeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'presets and manual controls fit a narrow screen with large text',
    (tester) async {
      final controller = AlarmController(
        gateway: FakeAlarmGateway(),
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      await _openEditor(tester, controller, width: 320, textScale: 1.5);

      for (final preset in WakePreset.values) {
        final choice = _preset(preset);
        await _tap(tester, choice);
        expect(tester.getSize(choice).height, greaterThanOrEqualTo(48));
        expect(_save.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await _tap(tester, _advanced);
      await _reveal(
        tester,
        find.byKey(const ValueKey('challenge-kind-sequence')),
      );
      expect(_save.hitTestable(), findsOneWidget);
      await _reveal(tester, find.byKey(const ValueKey('alarm-title')));
      expect(_save.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a rejected save stays visible beside the reachable retry button',
    (tester) async {
      final gateway = FakeAlarmGateway()..rejectSchedule = true;
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      await _openEditor(tester, controller, width: 320, textScale: 1.5);
      await _tap(tester, _preset(WakePreset.gentle));
      await _reveal(tester, _advanced);
      await tester.tap(_save);
      await tester.pumpAndSettle();

      final error = find.byKey(const ValueKey('alarm-save-error'));
      expect(error.hitTestable(), findsOneWidget);
      expect(find.text('Разрешение не предоставлено'), findsOneWidget);
      expect(_save.hitTestable(), findsOneWidget);
      expect(find.byType(AlarmEditor), findsOneWidget);
      expect(find.byKey(const ValueKey('escalate-on-snooze')), findsNothing);
      gateway.rejectSchedule = false;
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(WakePreset.matching(controller.alarms.single), WakePreset.gentle);
      expect(find.byType(AlarmEditor), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
