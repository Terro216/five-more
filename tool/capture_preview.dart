// Optional real-widget screenshots: FIVE_MORE_FLUTTER_SDK=/path/to/flutter
// flutter test tool/capture_preview.dart. Images go to ignored artifacts/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/models/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/alarm_fakes.dart';

void main() {
  setUpAll(() async {
    final sdk = Platform.environment['FIVE_MORE_FLUTTER_SDK'];
    if (sdk == null) {
      throw StateError('Set FIVE_MORE_FLUTTER_SDK to your Flutter SDK.');
    }
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family);
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
    }
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
      difficulty: ChallengeDifficulty.medium,
    );
    final gateway = FakeAlarmGateway();
    gateway.nativeAlarms[alarm.id] = alarm;
    final controller = AlarmController(
      gateway: gateway,
      storage: MemoryAlarmStorage(),
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
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
