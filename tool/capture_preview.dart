// Optional real-widget screenshots: FIVE_MORE_FLUTTER_SDK=/path/to/flutter
// flutter test tool/capture_preview.dart. Images go to ignored artifacts/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/device_check_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/alarm_fakes.dart';
import '../test/device_check_controller_test.dart' show DeviceCheckGateway;

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

  testWidgets('capture actual mobile layouts', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final alarm = Alarm.fresh().copyWith(
      title: 'Спокойное утро',
      challengeKind: ChallengeKind.mixed,
      difficulty: ChallengeDifficulty.easy,
    );
    final gateway = DeviceCheckGateway()
      ..currentTime = DateTime(2026, 10, 22, 7, 30);
    gateway.nativeAlarms[alarm.id] = alarm;
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
      now: () => gateway.currentTime,
    );
    await controller.initialize(startPolling: false);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: FiveMoreApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
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

    await capture('01-home');
    await tester.tap(find.text('Задания'));
    await tester.pumpAndSettle();
    await capture('02-challenges');
    await tester.tap(find.text('Счёт'));
    await tester.pumpAndSettle();
    await capture('03-math');
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ChallengeScreen(
          kind: ChallengeKind.sequence,
          difficulty: ChallengeDifficulty.medium,
          practice: true,
          onComplete: navigator.pop,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture('09-sequence');
    for (final number in [1, 2]) {
      final tile = find.byKey(ValueKey('sequence-number-$number'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }
    await capture('10-sequence-progress');
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AlarmEditor(controller: controller, alarm: alarm),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(ChoiceChip, 'Легко'),
      200,
    );
    await tester.pumpAndSettle();
    await capture('11-escalation-editor');
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подъём'));
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeviceCheckScreen(controller: controller, sourceAlarmId: alarm.id),
      ),
    );
    await tester.pumpAndSettle();
    await capture('04-device-check');
    final start = find.byKey(const ValueKey('device-check-start'));
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    await capture('05-lock-phone');
    gateway.currentTime = gateway.currentTime.add(const Duration(seconds: 21));
    await tester.pump(const Duration(seconds: 1));
    await capture('06-check-feedback');
    await controller.finishDeviceCheck(heard: true);
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await capture('07-home-checked');
    gateway.currentTime = DateTime(2026, 10, 22, 7, 40);
    gateway.ringing = RingingAlarm(
      alarm: alarm,
      occurrenceId: 'capture-morning',
      firedAt: gateway.currentTime,
      snoozesUsed: 2,
    );
    await controller.poll();
    await tester.pumpAndSettle();
    await capture('08-ringing');
    await tester.pumpWidget(const SizedBox.shrink());
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
