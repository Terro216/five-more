// Synthetic UI evidence; this does not test a physical alarm or photo picker.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/alarm_home.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/background_frame.dart';
import 'package:five_more/models/sleep_session.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:five_more/services/sleep_journal.dart';
import 'package:five_more/features/sleep/sleep_review.dart';
import 'package:five_more/features/alarms/background_editor.dart';
import 'package:five_more/services/local_database.dart';
import 'package:five_more/services/native_extras.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/alarm_fakes.dart';

void main() {
  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    LocalDatabase.instance = LocalDatabase(path: inMemoryDatabasePath);
    await LocalDatabase.instance.database;
    final sdk = Platform.environment['FIVE_MORE_FLUTTER_SDK']!;
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Light.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          File('$sdk/bin/cache/artifacts/material_fonts/$file')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      }
      await loader.load();
    }
  });
  tearDownAll(() => LocalDatabase.instance.close());

  testWidgets('personalization in both themes and phone sizes', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    late Uint8List image;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 400, 900),
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 0),
            const Offset(0, 900),
            [const Color(0xFFF4C680), const Color(0xFF326F80)],
          ),
      );
      canvas.drawCircle(
        const Offset(290, 210),
        90,
        Paint()..color = const Color(0xFFFFF0C0),
      );
      canvas.drawOval(
        const Rect.fromLTWH(-160, 380, 750, 800),
        Paint()..color = const Color(0xFF284C3B),
      );
      canvas.drawOval(
        const Rect.fromLTWH(110, 540, 600, 600),
        Paint()..color = const Color(0xFF102D30),
      );
      final picture = recorder.endRecording();
      final raster = await picture.toImage(400, 900);
      image = (await raster.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
      raster.dispose();
      picture.dispose();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          NativeExtras.channel,
          (call) async => call.method == 'readBackground' ? image : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeExtras.channel, null),
    );
    const alarm = Alarm(
      id: 'capture',
      hour: 7,
      minute: 30,
      weekdays: [1, 2, 3, 4, 5],
      dismissalMode: 'normal',
      background: '00000000-0000-4000-8000-000000000001.jpg',
      backgroundFrame: BackgroundFrame(x: .7, y: .3, zoom: 1.5),
    );
    final now = DateTime(2026, 11, 11, 7, 35);
    final postponed = RingingAlarm(
      alarm: alarm,
      occurrenceId: 'morning',
      firedAt: now.subtract(const Duration(minutes: 5)),
      snoozesUsed: 2,
      snoozedMinutes: 10,
      snoozedUntil: now.add(const Duration(minutes: 5)),
    );
    final gateway = FakeAlarmGateway()
      ..nativeAlarms[alarm.id] = alarm
      ..snoozedAlarms.add(postponed);
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage()
        ..snapshot = AlarmSnapshot(
          alarms: [alarm],
          events: [
            for (var i = 0; i < 2; i++)
              AlarmEvent(
                eventId: 'snooze-$i',
                alarmId: alarm.id,
                occurrenceId: 'morning',
                type: 'snoozed',
                at: now.subtract(Duration(minutes: i)),
              ),
          ],
        ),
      now: () => now,
    );
    await controller.initialize(startPolling: false);
    addTearDown(controller.dispose);
    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final narrow in [false, true]) {
        final size = narrow ? const Size(320, 640) : const Size(390, 844);
        tester.view.physicalSize = size;
        final boundary = GlobalKey();
        final prefix = 'v084-${brightness.name}-${size.width.toInt()}';
        Future<void> show(Widget page) async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                key: UniqueKey(),
                debugShowCheckedModeBanner: false,
                theme: fiveMoreTheme(brightness: brightness),
                locale: const Locale('ru'),
                supportedLocales: const [Locale('ru'), Locale('en')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(narrow ? 1.5 : 1)),
                  child: child!,
                ),
                home: page,
              ),
            ),
          );
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
        }

        await show(AlarmHome(controller: controller));
        await _capture(tester, boundary, '$prefix-home');
        await tester.scrollUntilVisible(
          find.text('Переносы сегодня: 2'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '$prefix-snooze-count');
        for (final tab in [
          ('Задания', 'challenges'),
          ('Вечер', 'bedtime'),
          ('История', 'history'),
        ]) {
          await tester.tap(find.text(tab.$1).last);
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          await _capture(tester, boundary, '$prefix-${tab.$2}');
        }
        await show(
          BackgroundEditor(
            name: alarm.background,
            initial: alarm.backgroundFrame,
          ),
        );
        await _capture(tester, boundary, '$prefix-crop');
        final event = AlarmEvent(
          eventId: 'end',
          alarmId: alarm.id,
          occurrenceId: 'second',
          type: 'dismissed',
          at: now,
        );
        final journal = SleepJournal()..ready = true;
        await show(
          SleepReview(
            journal: journal,
            event: event,
            session: SleepSession(
              id: 'first',
              occurrences: const ['first', 'second'],
              lastEvent: event,
            ),
          ),
        );
        await tester.scrollUntilVisible(
          find.text('Считать отдельным сном'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '$prefix-sleep');
        await tester.pumpWidget(const SizedBox.shrink());
        journal.dispose();
        await show(AlarmEditor(controller: controller, alarm: alarm));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('pick-alarm-background')),
          240,
          scrollable: find
              .byWidgetPredicate(
                (w) =>
                    w is Scrollable &&
                    axisDirectionToAxis(w.axisDirection) == Axis.vertical,
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '$prefix-editor');
        await show(
          RingingScreen(
            controller: controller,
            ringing: RingingAlarm(
              alarm: alarm,
              occurrenceId: 'ringing',
              firedAt: now,
              snoozesUsed: 0,
            ),
          ),
        );
        await _capture(tester, boundary, '$prefix-ringing');
        await show(
          RingingScreen(
            controller: controller,
            ringing: postponed,
            allowBack: true,
            disableAlarm: true,
          ),
        );
        await _capture(tester, boundary, '$prefix-snoozed');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  expect(tester.takeException(), isNull);
  // Replace only the widget-test engine's Ahem fallback, as in capture_080.
  InlineSpan deviceFont(InlineSpan span, [String? parent]) {
    if (span is! TextSpan) return span;
    final original = span.style?.fontFamily ?? parent;
    final family = original == null || original == 'Ahem' ? 'Roboto' : original;
    return TextSpan(
      text: span.text,
      style: (span.style ?? const TextStyle()).copyWith(fontFamily: family),
      children: span.children?.map((s) => deviceFont(s, family)).toList(),
      recognizer: span.recognizer,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
    );
  }

  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    paragraph.text = deviceFont(paragraph.text);
  }
  await tester.pump();
  expect(tester.takeException(), isNull);
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('artifacts/screenshots/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}
