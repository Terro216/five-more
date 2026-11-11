import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/appearance_settings.dart';
import 'package:five_more/services/native_extras.dart';
import 'package:five_more/widgets/alarm_background.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';
import 'ui_helpers.dart';

const _photo = '00000000-0000-4000-8000-000000000001.jpg';
const _alarm = Alarm(
  id: 'wake',
  hour: 7,
  minute: 30,
  dismissalMode: 'normal',
  weekdays: [1, 2, 3, 4, 5],
  background: _photo,
);
final _now = DateTime(2026, 11, 11, 7, 35);
RingingAlarm _postponed(Alarm alarm) => RingingAlarm(
  alarm: alarm,
  occurrenceId: 'same-morning',
  firedAt: _now.subtract(const Duration(minutes: 5)),
  snoozesUsed: 2,
  snoozedMinutes: 10,
  snoozedUntil: _now.add(const Duration(minutes: 5)),
);

class _WakeGateway extends FakeAlarmGateway {
  final requests =
      <({String id, String? occurrence, int? generation, bool emergency})>[];
  bool failDismiss = false;
  bool failCancel = false;
  @override
  Future<AlarmResult> cancel(String id) async => failCancel
      ? const AlarmResult(ok: false, error: 'Сбой расписания.')
      : super.cancel(id);
  @override
  Future<AlarmResult> dismiss(
    String id, {
    bool emergency = false,
    String? occurrenceId,
    int? generation,
  }) async {
    final active = ringing?.alarm.id == id
        ? ringing
        : snoozedAlarms.where((a) => a.alarm.id == id).firstOrNull;
    if (failDismiss ||
        active == null ||
        active.occurrenceId != occurrenceId ||
        active.snoozesUsed != generation) {
      return const AlarmResult(
        ok: false,
        error: 'Не удалось завершить подъём.',
      );
    }
    requests.add((
      id: id,
      occurrence: occurrenceId,
      generation: generation,
      emergency: emergency,
    ));
    dismissCalls.add(id);
    if (ringing?.alarm.id == id) ringing = null;
    snoozedAlarms.removeWhere((a) => a.alarm.id == id);
    pendingEvents.add(
      AlarmEvent(
        eventId: 'finished-$id',
        alarmId: id,
        occurrenceId: occurrenceId!,
        type: emergency ? 'emergency_dismissed' : 'dismissed',
        at: _now,
        snoozesUsed: generation!,
      ),
    );
    return const AlarmResult(ok: true);
  }
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find
        .byWidgetPredicate(
          (w) =>
              w is Scrollable &&
              axisDirectionToAxis(w.axisDirection) == Axis.vertical,
        )
        .first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<AlarmController> _open(
  WidgetTester tester,
  FakeAlarmGateway gateway, {
  Alarm alarm = _alarm,
  double width = 390,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, width == 320 ? 640 : 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  gateway.nativeAlarms[alarm.id] = alarm;
  final controller = AlarmController(
    gateway: gateway,
    storage: MemoryAlarmStorage()..snapshot = AlarmSnapshot(alarms: [alarm]),
    now: () => _now,
  );
  await controller.initialize(startPolling: false);
  await tester.pumpWidget(FiveMoreApp(controller: controller));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUp(() {
    AppearanceSettings.instance.mode = ThemeMode.dark;
  });
  tearDown(() {
    AppearanceSettings.instance.mode = ThemeMode.dark;
  });

  test('photo references migrate safely and survive JSON and edits', () {
    expect(Alarm.fromJson(_alarm.toJson()).background, _photo);
    expect(_alarm.copyWith(minute: 15).background, _photo);
    expect(
      Alarm.fromJson({..._alarm.toJson()}..remove('background')).background,
      '',
    );
    for (final value in [
      '../private.jpg',
      'https://example.test/photo.jpg',
      '/photo.jpg',
      12,
    ]) {
      expect(
        Alarm.fromJson({..._alarm.toJson(), 'background': value}).background,
        '',
      );
    }
  });

  test('native bridge restores the postponed occurrence and carries its identity when finishing', () async {
    const channel = MethodChannel('five_more/alarm');
    MethodCall? dismissal;
    final payload = {
      ..._alarm.toJson(),
      'alarm': _alarm.toJson(),
      'occurrenceId': 'same-morning',
      'state': 'snoozed',
      'snoozesUsed': 2,
      'snoozedMinutes': 10,
      'nextAt': _now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSnoozedAlarms') {
            return [
              payload,
              {...payload, 'state': 'dismissed'},
            ];
          }
          if (call.method == 'getRingingAlarm') return payload;
          dismissal = call;
          return {'ok': true};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final gateway = NativeAlarmGateway();
    expect(await gateway.getRingingAlarm(), isNull);
    final restored = (await gateway.getSnoozedAlarms()).single;
    expect(restored.snoozedUntil, _now.add(const Duration(minutes: 5)));
    expect(restored.snoozesUsed, 2);
    await gateway.dismiss(
      restored.alarm.id,
      occurrenceId: restored.occurrenceId,
      generation: restored.snoozesUsed,
    );
    expect(dismissal!.arguments, {
      'id': 'wake',
      'emergency': false,
      'occurrenceId': 'same-morning',
      'generation': 2,
    });
  });

  for (final unavailable in [false, true]) {
    test(
      'finishing a snoozed alarm preserves an overlapping ring with failed storage ($unavailable)',
      () async {
        const other = Alarm(id: 'other', hour: 7, minute: 35);
        final gateway = _WakeGateway()
          ..nativeAlarms[_alarm.id] = _alarm
          ..snoozedAlarms.add(_postponed(_alarm))
          ..ringing = RingingAlarm(
            alarm: other,
            occurrenceId: 'other-ring',
            firedAt: _now,
            snoozesUsed: 0,
          );
        final storage = MemoryAlarmStorage()..failLoad = unavailable;
        final controller = AlarmController(gateway: gateway, storage: storage);
        addTearDown(controller.dispose);
        await controller.initialize(startPolling: false);
        storage.failSave = true;
        final result = await controller.dismiss(
          alarmId: 'wake',
          occurrenceId: 'same-morning',
          generation: 2,
          emergency: true,
        );
        expect(result.ok, isTrue);
        expect(controller.ringing?.occurrenceId, 'other-ring');
        expect(gateway.pendingEvents.single.type, 'emergency_dismissed');
        expect(gateway.acknowledged, isEmpty);
        expect(controller.snoozedAlarms, isEmpty);
      },
    );
  }

  test(
    'an obsolete occurrence or snooze generation never completes another wake',
    () async {
      final gateway = _WakeGateway()..snoozedAlarms.add(_postponed(_alarm));
      final controller = AlarmController(
        gateway: gateway,
        storage: MemoryAlarmStorage(),
      );
      addTearDown(controller.dispose);
      await controller.initialize(startPolling: false);
      for (final identity in [('old-morning', 2), ('same-morning', 1)]) {
        expect(
          (await controller.dismiss(
            alarmId: 'wake',
            occurrenceId: identity.$1,
            generation: identity.$2,
          )).ok,
          isFalse,
        );
      }
      expect(gateway.requests, isEmpty);
      expect(gateway.snoozedAlarms, hasLength(1));
    },
  );

  testWidgets(
    'failure to disable future rings remains visible after finishing this wake',
    (tester) async {
      final gateway = _WakeGateway()
        ..snoozedAlarms.add(_postponed(_alarm))
        ..failCancel = true;
      await _open(tester, gateway);
      final toggle = find.byKey(const ValueKey('alarm-toggle-wake'));
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ringing-start-challenge')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Подъём завершён, но выключить будущие звонки не удалось.',
        ),
        findsOneWidget,
      );
      expect(gateway.snoozedAlarms, isEmpty);
      expect(gateway.nativeAlarms['wake']!.enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'light and dark colors meet contrast and theme choice survives reload',
    () async {
      double contrast(Color a, Color b) {
        final x = a.computeLuminance(), y = b.computeLuminance();
        return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
      }

      for (final p in [AppPalette.dark, AppPalette.light]) {
        final overPhoto = Color.alphaBlend(
          p.ink.withValues(alpha: p == AppPalette.dark ? .80 : .88),
          p == AppPalette.dark ? Colors.white : Colors.black,
        );
        for (final text in [p.foreground, p.muted, p.morning]) {
          expect(contrast(text, overPhoto), greaterThanOrEqualTo(4.5));
        }
        for (final background in [p.ink, p.panel]) {
          for (final text in [
            p.foreground,
            p.muted,
            p.morning,
            p.red,
            p.green,
            p.blue,
          ]) {
            expect(contrast(text, background), greaterThanOrEqualTo(4.5));
          }
        }
      }
      final settings = AppearanceSettings();
      await settings.load();
      expect(settings.mode, ThemeMode.dark);
      await settings.toggle();
      final reloaded = AppearanceSettings();
      await reloaded.load();
      expect(reloaded.mode, ThemeMode.light);
      settings.dispose();
      reloaded.dispose();
    },
  );

  for (final reject in [false, true]) {
    testWidgets(
      'quick Done enables a disabled alarm only after native success ($reject)',
      (tester) async {
        final gateway = FakeAlarmGateway()..rejectSchedule = reject;
        final controller = await _open(
          tester,
          gateway,
          alarm: _alarm.copyWith(enabled: false),
        );
        final time = find.byKey(const ValueKey('alarm-time-wake'));
        await _reveal(tester, time);
        await tester.tap(time);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('time-minute-input')),
          '41',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Готово'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Готово'));
        await tester.pumpAndSettle();
        expect(gateway.scheduleCalls.single.enabled, isTrue);
        expect(controller.alarms.single.enabled, !reject);
        expect(controller.alarms.single.minute, reject ? 30 : 41);
        if (reject) {
          expect(find.text('Разрешение не предоставлено'), findsWidgets);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final challenge in [false, true]) {
    testWidgets(
      'snoozed alarm is reachable after reopening without a notification ($challenge)',
      (tester) async {
        final alarm = _alarm.copyWith(
          dismissalMode: challenge ? 'challenge' : 'normal',
        );
        final gateway = _WakeGateway()..snoozedAlarms.add(_postponed(alarm));
        final controller = await _open(
          tester,
          gateway,
          alarm: alarm,
          width: 320,
          scale: 1.5,
        );
        expect(controller.ringing, isNull);
        final recovery = find.byKey(const ValueKey('snoozed-wake'));
        await _reveal(tester, recovery);
        await tester.tap(recovery);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('snoozed-until')), findsOneWidget);
        expect(find.byKey(const ValueKey('ringing-snooze')), findsNothing);
        expect(find.byKey(const ValueKey('quiet-alarm')), findsNothing);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(gateway.snoozedAlarms.single.snoozesUsed, 2);
        expect(gateway.dismissCalls, isEmpty);
        // Disabling the schedule opens an explicit completion flow.
        final toggle = find.byKey(const ValueKey('alarm-toggle-wake'));
        await _reveal(tester, toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final finish = find.byKey(const ValueKey('ringing-start-challenge'));
        await tester.ensureVisible(finish);
        await tester.tap(finish);
        await tester.pumpAndSettle();
        if (challenge) {
          expect(gateway.dismissCalls, isEmpty);
          tester
              .widget<ChallengeScreen>(find.byType(ChallengeScreen))
              .onComplete();
          await tester.pumpAndSettle();
        }
        expect(gateway.requests.single.occurrence, 'same-morning');
        expect(gateway.requests.single.generation, 2);
        expect(gateway.requests.single.emergency, isFalse);
        expect(gateway.cancelCalls, ['wake']);
        expect(controller.alarms.single.enabled, isFalse);
        expect(find.byType(RingingScreen), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'failed snoozed completion remains actionable and emergency is separate',
    (tester) async {
      final gateway = _WakeGateway()
        ..snoozedAlarms.add(_postponed(_alarm))
        ..failDismiss = true;
      await _open(tester, gateway);
      final recovery = find.byKey(const ValueKey('snoozed-wake'));
      await _reveal(tester, recovery);
      await tester.tap(recovery);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ringing-start-challenge')));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось завершить подъём.'), findsOneWidget);
      expect(gateway.snoozedAlarms, hasLength(1));
      gateway.failDismiss = false;
      await tester.tap(find.byKey(const ValueKey('ringing-emergency')));
      await tester.pumpAndSettle();
      await completeEmergencyHold(tester);
      await tester.pumpAndSettle();
      expect(gateway.requests.single.emergency, isTrue);
      expect(
        gateway.cancelCalls,
        isEmpty,
      ); // Finish this occurrence; keep the weekly schedule.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'theme toggle changes all tabs and an open editor on a small phone',
    (tester) async {
      await _open(tester, FakeAlarmGateway(), width: 320, scale: 1.5);
      await tester.tap(find.byKey(const ValueKey('toggle-theme')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(NavigationBar))).brightness,
        Brightness.light,
      );
      for (final tab in ['Задания', 'Вечер', 'История', 'Подъём']) {
        await tester.tap(find.text(tab).last);
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('add-alarm')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlarmEditor))).brightness,
        Brightness.light,
      );
      await _reveal(
        tester,
        find.byKey(const ValueKey('pick-alarm-background')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local photo picks, persists and can be removed; broken images keep controls usable',
    (tester) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
      });
      var broken = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeExtras.channel, (call) async {
            if (call.method == 'pickBackground') return _photo;
            if (call.method == 'readBackground') {
              if (broken) throw PlatformException(code: 'missing');
              return bytes;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeExtras.channel, null),
      );
      final gateway = FakeAlarmGateway();
      final controller = await _open(
        tester,
        gateway,
        alarm: _alarm.copyWith(background: ''),
      );
      await tester.tap(find.byKey(const ValueKey('add-alarm')));
      await tester.pumpAndSettle();
      final pick = find.byKey(const ValueKey('pick-alarm-background'));
      await _reveal(tester, pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlarmBackground>(find.byType(AlarmBackground)).name,
        _photo,
      );
      await _reveal(tester, find.text('Убрать фон'));
      await tester.tap(find.text('Убрать фон'));
      await tester.pumpAndSettle();
      expect(find.byType(AlarmBackground), findsNothing);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-alarm')));
      await tester.pumpAndSettle();
      expect(gateway.scheduleCalls.single.background, _photo);
      broken = true;
      gateway.ringing = RingingAlarm(
        alarm: controller.alarms.last,
        occurrenceId: 'with-photo',
        firedAt: _now,
        snoozesUsed: 0,
      );
      await controller.poll();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ringing-start-challenge')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ringing-emergency')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
