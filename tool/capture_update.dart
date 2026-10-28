// Run with FIVE_MORE_FLUTTER_SDK set to the pinned SDK. Captures are synthetic UI fixtures.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/features/history/history_view.dart';
import 'package:five_more/features/sleep/bedtime_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/device_alarm_check.dart';
import 'package:five_more/models/sleep_entry.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:five_more/services/native_extras.dart';

import '../test/alarm_fakes.dart';
import '../test/ui_helpers.dart';

void main() {
  setUpAll(() async {
    final sdk = Platform.environment['FIVE_MORE_FLUTTER_SDK'];
    if (sdk == null) {
      throw StateError('Set FIVE_MORE_FLUTTER_SDK to your Flutter SDK.');
    }
    final loader = FontLoader('Roboto');
    for (final file in [
      'Roboto-Regular.ttf',
      'Roboto-Light.ttf',
      'Roboto-Bold.ttf',
    ]) {
      loader.addFont(
        File('$sdk/bin/cache/artifacts/material_fonts/$file')
            .readAsBytes()
            .then((data) => ByteData.sublistView(data)),
      );
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes()
          .then((data) => ByteData.sublistView(data)),
    );
    await icons.load();
  });

  testWidgets('capture morning update on phones', (tester) async {
    // This capture harness runs as a Flutter widget test.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    for (final channel in [
      'dev.fluttercommunity.plus/sensors/method',
      'dev.fluttercommunity.plus/sensors/accelerometer',
      'dev.fluttercommunity.plus/sensors/user_accel',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeExtras.channel, (call) async {
          if (call.method == 'stopRecording') {
            return {'file': 'capture-note.m4a', 'seconds': 95};
          }
          return null;
        });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const alarm = Alarm(
      id: 'capture',
      hour: 7,
      minute: 30,
      title: 'Утренняя прогулка',
      weekdays: [1, 2, 3, 4, 5],
      moveSnoozeButton: true,
      challengeKind: ChallengeKind.mixed,
      difficulty: ChallengeDifficulty.hard,
    );
    final now = DateTime(2026, 10, 27, 20, 15);
    final gateway = FakeAlarmGateway()..nativeAlarms[alarm.id] = alarm;
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(
        alarms: [alarm],
        deviceCheck: DeviceAlarmCheck(
          sourceAlarmId: alarm.id,
          previewAlarmId: 'preview:done',
          startedAt: now.subtract(const Duration(days: 1)),
          dueAt: now.subtract(const Duration(days: 1)),
          heard: true,
          confirmedAt: now.subtract(const Duration(days: 1)),
        ),
      );
    final controller = AlarmController(
      gateway: gateway,
      storage: storage,
      now: () => now,
    );
    await controller.initialize(startPolling: false);
    addTearDown(controller.dispose);
    final journal = SleepJournal()..ready = true;
    addTearDown(journal.dispose);
    for (var i = 1; i <= 12; i++) {
      final at = DateTime(2026, 10, i + 10, 7, 30);
      journal.entries.add(
        SleepEntry(
          occurrenceId: 'sleep$i',
          wokeAt: at,
          bedAt: at.subtract(Duration(minutes: [420, 480, 450][i % 3])),
          sleepQuality: [3, 5, 4][i % 3],
          wakeQuality: [2, 4, 4][i % 3],
        ),
      );
    }
    final events = <AlarmEvent>[];
    for (var i = 0; i < 12; i++) {
      final at = DateTime(2026, 10, i + 11, 7, 30);
      events.add(
        AlarmEvent(
          eventId: 'start$i',
          alarmId: alarm.id,
          occurrenceId: 'o$i',
          type: 'fired',
          at: at,
        ),
      );
      for (var n = 0; n < i % 3; n++) {
        events.add(
          AlarmEvent(
            eventId: 's$i$n',
            alarmId: alarm.id,
            occurrenceId: 'o$i',
            type: 'snoozed',
            at: at.add(Duration(minutes: n * 5 + 1)),
          ),
        );
      }
      events.add(
        AlarmEvent(
          eventId: 'end$i',
          alarmId: alarm.id,
          occurrenceId: 'o$i',
          type: i == 4 ? 'emergency_dismissed' : 'dismissed',
          at: at.add(Duration(minutes: 3 + i % 3 * 5)),
        ),
      );
    }
    for (final width in [390.0, 320.0]) {
      tester.view.physicalSize = Size(width, width == 390 ? 844 : 640);
      final scale = width == 390 ? 1.0 : 1.5;
      Future<GlobalKey> mount(Widget screen, {bool settle = true}) async {
        await tester.pumpWidget(const SizedBox.shrink());
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: fiveMoreTheme(),
              locale: const Locale('ru'),
              supportedLocales: const [Locale('ru'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: screen,
            ),
          ),
        );
        if (settle) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump(const Duration(milliseconds: 100));
        }
        return boundary;
      }

      var key = await mount(AlarmHome(controller: controller));
      await _capture(tester, key, 'update-home-${width.toInt()}');
      await controller.setEnabled(alarm, false);
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-home-disabled-${width.toInt()}');
      await controller.setEnabled(alarm, true);
      await tester.pumpAndSettle();
      final quickTime = find.byKey(const ValueKey('alarm-time-capture'));
      await tester.scrollUntilVisible(quickTime, 180);
      await tester.ensureVisible(quickTime);
      await tester.pumpAndSettle();
      await tester.tap(quickTime);
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-quick-time-${width.toInt()}');
      key = await mount(AlarmEditor(controller: controller));
      await _capture(tester, key, 'update-clock-${width.toInt()}');
      final dial = find.byKey(const ValueKey('time-dial'));
      await tester.ensureVisible(dial);
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(dial) + Offset(tester.getSize(dial).width * .4, 0),
      );
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-clock-minutes-${width.toInt()}');
      final title = find.byKey(const ValueKey('alarm-title'));
      await tester.scrollUntilVisible(
        title,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-alarm-title-${width.toInt()}');
      key = await mount(AlarmEditor(controller: controller));
      await tester.tap(find.text('Вздремнуть'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-nap-${width.toInt()}');
      key = await mount(
        Scaffold(
          body: HistoryView(
            events: events.reversed.toList(),
            journal: journal,
            now: now,
          ),
        ),
      );
      await _capture(tester, key, 'update-history-${width.toInt()}');
      key = await mount(Scaffold(body: BedtimeScreen(journal: journal)));
      await _capture(tester, key, 'update-bedtime-${width.toInt()}');
      final record = find.byKey(const ValueKey('record-morning-note'));
      await tester.ensureVisible(record);
      await tester.pumpAndSettle();
      await tester.tap(record);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 95));
      await _capture(tester, key, 'update-long-recording-${width.toInt()}');
      await tester.tap(record);
      await tester.pumpAndSettle();
      for (var used = 0; used < 2; used++) {
        gateway.ringing = RingingAlarm(
          alarm: alarm,
          occurrenceId: 'capture-ring',
          firedAt: now,
          snoozesUsed: used,
        );
        await controller.poll();
        key = await mount(
          RingingScreen(controller: controller, ringing: gateway.ringing!),
        );
        await _capture(tester, key, 'update-ring-$used-${width.toInt()}');
      }
      await tester.longPress(find.byKey(const ValueKey('ringing-snooze')));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-snooze-slider-${width.toInt()}');
      await tester.tap(find.byKey(const ValueKey('ringing-emergency')));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-emergency-${width.toInt()}');
      await enterEmergencyCode(tester);
      final hold = find.byKey(const ValueKey('emergency-hold'));
      await tester.ensureVisible(hold);
      await tester.pumpAndSettle();
      await _capture(tester, key, 'update-emergency-hold-${width.toInt()}');
      gateway.ringing = null;
      await controller.poll();
      for (final kind in [
        ChallengeKind.math,
        ChallengeKind.stroop,
        ChallengeKind.flags,
        ChallengeKind.memory,
        ChallengeKind.sequence,
        ChallengeKind.shake,
        ChallengeKind.maze,
      ]) {
        key = await mount(
          ChallengeScreen(
            kind: kind,
            difficulty: ChallengeDifficulty.hard,
            practice: true,
            onComplete: () {},
          ),
          settle: kind != ChallengeKind.maze,
        );
        await _capture(tester, key, 'update-${kind.name}-${width.toInt()}');
        if (kind == ChallengeKind.maze) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('calibrate-tilt')),
          );
          await tester.pump();
          await _capture(tester, key, 'update-maze-calibrate-${width.toInt()}');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  expect(tester.takeException(), isNull);
  // The test engine uses Ahem for a null fontFamily, unlike the mobile
  // engine's device font. Button-local TextStyles can deliberately have a
  // null family even when the app theme specifies Roboto. Replace only
  // that test fallback at the render boundary; leave production widgets,
  // layout rules, text content and explicit icon fonts unchanged.
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    paragraph.text = _withDeviceFontFallback(paragraph.text);
  }
  await tester.pump();
  expect(tester.takeException(), isNull);
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('artifacts/screenshots/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

InlineSpan _withDeviceFontFallback(InlineSpan span, {String? inheritedFamily}) {
  if (span is! TextSpan) return span;
  final family = span.style?.fontFamily ?? inheritedFamily;
  final resolved = family == null || family == 'Ahem' ? 'Roboto' : family;
  return TextSpan(
    text: span.text,
    style: (span.style ?? const TextStyle()).copyWith(fontFamily: resolved),
    children: span.children
        ?.map(
          (child) => _withDeviceFontFallback(child, inheritedFamily: resolved),
        )
        .toList(),
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}
