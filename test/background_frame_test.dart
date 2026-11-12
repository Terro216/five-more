import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/background_editor.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/background_frame.dart';
import 'package:five_more/services/native_extras.dart';
import 'package:five_more/widgets/framed_photo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _name = '00000000-0000-4000-8000-000000000001.jpg';

Future<void> _loaded(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(FramedPhoto).evaluate().isNotEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  test('legacy and invalid framing stays bounded; chosen framing survives native restoration', () async {
    expect(BackgroundFrame.fromJson(null), const BackgroundFrame());
    expect(
      BackgroundFrame.fromJson({
        'x': -5,
        'y': 9,
        'zoom': double.nan,
        'turns': 10,
      }),
      const BackgroundFrame(x: 0, y: 1, turns: 3),
    );
    expect(
      BackgroundFrame.fromJson({'zoom': double.infinity}),
      const BackgroundFrame(),
    );
    const frame = BackgroundFrame(x: .1, y: .8, zoom: 2.3, turns: 1);
    const alarm = Alarm(
      id: 'photo',
      hour: 7,
      minute: 30,
      background: _name,
      backgroundFrame: frame,
    );
    expect(Alarm.fromJson(alarm.toJson()).backgroundFrame, frame);
    expect(
      Alarm.fromJson({...alarm.toJson()}..remove('backgroundFrame'))
          .backgroundFrame,
      const BackgroundFrame(),
    );
    final gateway = FakeAlarmGateway();
    final first = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    await first.initialize(startPolling: false);
    expect((await first.saveAlarm(alarm)).ok, isTrue);
    first.dispose();
    final restored = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
    );
    await restored.initialize(startPolling: false);
    expect(restored.alarms.single.backgroundFrame, frame);
    expect(restored.alarms.single.copyWith(minute: 45).backgroundFrame, frame);
    restored.dispose();
  });

  test('photo covers every viewport after pan, zoom and quarter turns without empty edges', () {
    for (final image in [
      const Size(400, 900),
      const Size(800, 400),
      const Size(1, 1),
    ]) {
      for (final viewport in [
        const Size(390, 844),
        const Size(320, 640),
        const Size(844, 390),
      ]) {
        for (var turns = 0; turns < 4; turns++) {
          for (final zoom in [1.0, 2.5, 4.0]) {
            for (final delta in [
              const Offset(-10000, -10000),
              Offset.zero,
              const Offset(10000, 10000),
            ]) {
              final next = positionBackground(
                BackgroundFrame(zoom: zoom, turns: turns),
                image,
                viewport,
                delta,
              );
              final rect = backgroundRect(image, viewport, next);
              expect(rect.left, lessThanOrEqualTo(.0001));
              expect(rect.top, lessThanOrEqualTo(.0001));
              expect(rect.right, greaterThanOrEqualTo(viewport.width - .0001));
              expect(
                rect.bottom,
                greaterThanOrEqualTo(viewport.height - .0001),
              );
            }
          }
        }
      }
    }
  });

  for (final narrow in [false, true]) {
    testWidgets(
      'pan, pinch, rotation, reset, apply and cancel work with narrow=$narrow',
      (tester) async {
        tester.view.physicalSize = narrow
            ? const Size(320, 640)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Uint8List bytes;
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(Colors.green, BlendMode.src);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 400, 400),
            Paint()..color = Colors.red,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(800, 400);
          bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List();
          image.dispose();
          picture.dispose();
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeExtras.channel, (_) async => bytes);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeExtras.channel, null),
        );
        var saved = const BackgroundFrame();
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(
              brightness: narrow ? Brightness.light : Brightness.dark,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(narrow ? 1.5 : 1)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    final selected = await Navigator.of(context)
                        .push<BackgroundFrame>(
                          MaterialPageRoute(
                            builder: (_) =>
                                BackgroundEditor(name: _name, initial: saved),
                          ),
                        );
                    if (selected != null) saved = selected;
                  },
                  child: const Text('Открыть'),
                ),
              ),
            ),
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('Открыть'));
          await _loaded(tester);
        }

        BackgroundFrame frame() =>
            tester.widget<FramedPhoto>(find.byType(FramedPhoto)).frame;
        await open();
        final canvas = find.byKey(const ValueKey('background-canvas'));
        await tester.drag(canvas, const Offset(-40, 0));
        await tester.pump();
        expect(frame().x, greaterThan(.5));
        final center = tester.getCenter(canvas);
        final a = await tester.startGesture(
          center - const Offset(25, 0),
          pointer: 1,
        );
        final b = await tester.startGesture(
          center + const Offset(25, 0),
          pointer: 2,
        );
        await tester.pump();
        await a.moveTo(center - const Offset(45, 0));
        await tester.pump();
        await b.moveTo(center + const Offset(45, 0));
        await tester.pump();
        await a.moveTo(center - const Offset(60, 0));
        await tester.pump();
        await b.moveTo(center + const Offset(60, 0));
        await tester.pump();
        await a.up();
        await b.up();
        expect(frame().zoom, greaterThan(1.2));
        await tester.tap(find.byKey(const ValueKey('background-rotate')));
        await tester.pump();
        expect(frame().turns, 1);
        await tester.tap(find.byKey(const ValueKey('background-reset')));
        await tester.pump();
        expect(frame(), const BackgroundFrame());
        await tester.tap(find.byTooltip('Увеличить фото'));
        await tester.pump();
        await tester.drag(canvas, const Offset(-25, -20));
        await tester.pump();
        final chosen = frame();
        await tester.tap(find.byKey(const ValueKey('background-apply')));
        await tester.pumpAndSettle();
        expect(saved, chosen);
        await open();
        expect(frame(), chosen);
        await tester.tap(find.byKey(const ValueKey('background-reset')));
        await tester.pump();
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(saved, chosen);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('missing image can be left without replacing the saved photo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => const BackgroundEditor(name: 'invalid'),
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось открыть фото'), findsOneWidget);
    expect(find.byKey(const ValueKey('background-apply')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
  });
}
