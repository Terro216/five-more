// Optional real-widget screenshots: FIVE_MORE_FLUTTER_SDK=/path/to/flutter
// flutter test tool/capture_preview.dart. Images go to ignored artifacts/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/five_more_app.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/alarm_editor.dart';
import 'package:five_more/features/alarms/device_check_screen.dart';
import 'package:five_more/features/alarms/ringing_screen.dart';
import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/challenge_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

    Future<void> capture(String name) => _capture(tester, boundary, name);

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
        builder: (_) => AlarmEditor(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await capture('12-quick-editor');
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AlarmEditor(controller: controller, alarm: alarm),
      ),
    );
    await tester.pumpAndSettle();
    final advanced = find.byKey(const ValueKey('alarm-advanced'));
    await _reveal(tester, advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await _reveal(tester, find.widgetWithText(ChoiceChip, 'Легко'));
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

  for (final variant in [
    (
      name: '13-ringing-small-200',
      surface: _PreviewSurface.ringing,
      size: const Size(320, 640),
      textScale: 2.0,
      safeInsets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: '14-math-small-200',
      surface: _PreviewSurface.math,
      size: const Size(320, 640),
      textScale: 2.0,
      safeInsets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: '15-ringing-landscape-150',
      surface: _PreviewSurface.ringing,
      size: const Size(844, 390),
      textScale: 1.5,
      safeInsets: const EdgeInsets.fromLTRB(44, 0, 44, 21),
    ),
    (
      name: '16-quick-editor-small-150',
      surface: _PreviewSurface.editor,
      size: const Size(320, 640),
      textScale: 1.5,
      safeInsets: const EdgeInsets.only(top: 24, bottom: 24),
    ),
  ]) {
    testWidgets('capture ${variant.name}', (tester) async {
      await _captureVariant(
        tester,
        name: variant.name,
        surface: variant.surface,
        size: variant.size,
        textScale: variant.textScale,
        safeInsets: variant.safeInsets,
      );
    });
  }

  for (final variant in [
    (name: '18-mirror', surface: _PreviewSurface.mirror, keyboard: false),
    (name: '19-captcha', surface: _PreviewSurface.captcha, keyboard: false),
    (
      name: '20-mirror-keyboard-small-200',
      surface: _PreviewSurface.mirror,
      keyboard: true,
    ),
    (
      name: '21-captcha-keyboard-small-200',
      surface: _PreviewSurface.captcha,
      keyboard: true,
    ),
  ]) {
    testWidgets('capture ${variant.name}', (tester) async {
      await _captureVariant(
        tester,
        name: variant.name,
        surface: variant.surface,
        size: variant.keyboard ? const Size(320, 640) : const Size(390, 844),
        textScale: variant.keyboard ? 2 : 1,
        safeInsets: const EdgeInsets.only(top: 24, bottom: 24),
        keyboardHeight: variant.keyboard ? 260 : 0,
      );
    });
  }

  testWidgets('capture moving snooze across native counters', (tester) async {
    await _captureMovingSnooze(tester);
  });

  testWidgets('capture optional protection and recovery states', (
    tester,
  ) async {
    await _captureProtection(tester);
  });
}

enum _PreviewSurface { ringing, math, editor, mirror, captcha }

Future<void> _captureVariant(
  WidgetTester tester, {
  required String name,
  required _PreviewSurface surface,
  required Size size,
  required double textScale,
  required EdgeInsets safeInsets,
  double keyboardHeight = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const alarm = Alarm(
    id: 'capture-variant',
    hour: 7,
    minute: 30,
    title: 'Спокойное утро',
    weekdays: [1, 2, 3, 4, 5],
    difficulty: ChallengeDifficulty.easy,
    escalateOnSnooze: true,
  );
  final gateway = DeviceCheckGateway()
    ..currentTime = DateTime(2026, 10, 22, 7, 40);
  gateway.nativeAlarms[alarm.id] = alarm;
  final ringing = RingingAlarm(
    alarm: alarm,
    occurrenceId: 'capture-$name',
    firedAt: gateway.currentTime,
    snoozesUsed: 2,
  );
  if (surface == _PreviewSurface.ringing) gateway.ringing = ringing;
  final controller = AlarmController(
    gateway: gateway,
    storage: MemoryAlarmStorage(),
    now: () => gateway.currentTime,
  );
  addTearDown(controller.dispose);
  await controller.initialize(startPolling: false);
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
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: safeInsets,
            viewPadding: safeInsets,
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: child!,
        ),
        home: switch (surface) {
          _PreviewSurface.ringing => RingingScreen(
            controller: controller,
            ringing: ringing,
          ),
          _PreviewSurface.math => ChallengeScreen(
            kind: ChallengeKind.math,
            difficulty: ChallengeDifficulty.hard,
            practice: true,
            onComplete: () {},
            onEmergencyExit: () {},
          ),
          _PreviewSurface.mirror || _PreviewSurface.captcha => ChallengeScreen(
            kind: surface == _PreviewSurface.mirror
                ? ChallengeKind.mirror
                : ChallengeKind.captcha,
            difficulty: ChallengeDifficulty.medium,
            onComplete: () {},
            onEmergencyExit: () {},
          ),
          // Open the editor through the Navigator so its ordinary back action
          // and app-bar layout are represented in the capture.
          _PreviewSurface.editor => const Scaffold(body: SizedBox.shrink()),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (surface == _PreviewSurface.editor) {
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => AlarmEditor(controller: controller),
          ),
        );
    await tester.pumpAndSettle();
  }
  if (keyboardHeight > 0) {
    final answer = find.byKey(const ValueKey('typed-challenge-answer'));
    await _reveal(tester, answer);
    await tester.showKeyboard(answer);
    await tester.pumpAndSettle();
    final emergency = find.text('Нужно срочно выключить');
    expect(emergency.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(emergency).bottom,
      lessThanOrEqualTo(size.height - keyboardHeight),
    );
    // A widget capture reserves the keyboard inset; it cannot render an OS IME.
  }
  await _capture(tester, boundary, name);
  if (surface == _PreviewSurface.math) {
    await _reveal(tester, find.byType(FilledButton).last);
    await _capture(tester, boundary, '17-math-answers-small-200');
  }
  await tester.pumpWidget(const SizedBox.shrink());
}

Future<void> _captureMovingSnooze(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const alarm = Alarm(
    id: 'capture-moving',
    hour: 7,
    minute: 30,
    title: 'Спокойное утро',
    difficulty: ChallengeDifficulty.easy,
    escalateOnSnooze: true,
    moveSnoozeButton: true,
  );
  final gateway = DeviceCheckGateway()
    ..currentTime = DateTime(2026, 10, 23, 7, 30);
  gateway.nativeAlarms[alarm.id] = alarm;
  RingingAlarm occurrence(int count) => RingingAlarm(
    alarm: alarm,
    occurrenceId: 'capture-moving-morning',
    firedAt: gateway.currentTime,
    snoozesUsed: count,
  );
  gateway.ringing = occurrence(0);
  final controller = AlarmController(
    gateway: gateway,
    storage: MemoryAlarmStorage(),
    now: () => gateway.currentTime,
  );
  addTearDown(controller.dispose);
  await controller.initialize(startPolling: false);
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
        home: RingingScreen(controller: controller, ringing: gateway.ringing!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final snooze = find.byKey(const ValueKey('ringing-snooze'));
  expect(snooze.hitTestable(), findsOneWidget);
  final before = tester.getRect(snooze);
  await _capture(tester, boundary, '22-moving-snooze-first');
  // Model the next native ring; a successful native snooze supplies this counter.
  gateway.currentTime = gateway.currentTime.add(const Duration(minutes: 5));
  gateway.ringing = occurrence(1);
  await controller.poll();
  await tester.pumpAndSettle();
  expect(snooze.hitTestable(), findsOneWidget);
  expect(tester.getRect(snooze).center.dx, isNot(before.center.dx));
  await _capture(tester, boundary, '23-moving-snooze-next');
  await tester.pumpWidget(const SizedBox.shrink());
}

class _ProtectionCaptureGateway extends DeviceCheckGateway {
  bool adminActive = false;
  String? restoreError;

  @override
  Future<AlarmDeviceStatus> status() async => AlarmDeviceStatus(
    platform: 'android',
    supported: true,
    exactAlarms: true,
    notifications: true,
    fullScreenIntent: true,
    alarms: nativeAlarms.values.toList(),
    activeTest: activeTest,
    batteryOptimized: true,
    alarmVolume: 5,
    alarmMaxVolume: 7,
    deviceAdminActive: adminActive,
    bootRecoverySupported: true,
    recoveryError: restoreError,
  );

  @override
  Future<void> requestPermissions({String? target}) async {
    if (target == 'deviceAdmin') adminActive = true;
    if (target == 'removeDeviceAdmin') adminActive = false;
  }
}

Future<void> _captureProtection(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final gateway = _ProtectionCaptureGateway();
  const alarm = Alarm(id: 'capture-protection', hour: 7, minute: 30);
  gateway.nativeAlarms[alarm.id] = alarm;
  final controller = AlarmController(
    gateway: gateway,
    storage: MemoryAlarmStorage(),
  );
  addTearDown(controller.dispose);
  await controller.initialize(startPolling: false);
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
        home: DeviceCheckScreen(controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final reliability = find.byKey(const ValueKey('device-reliability'));
  await _reveal(tester, reliability);
  await tester.tap(reliability);
  await tester.pumpAndSettle();
  final admin = find.byKey(const ValueKey('device-admin-change'));
  await _reveal(tester, admin);
  await _capture(tester, boundary, '24-protection-off');
  await tester.tap(admin);
  await tester.pumpAndSettle();
  await _capture(tester, boundary, '25-protection-confirm');
  await tester.tap(find.byKey(const ValueKey('device-admin-confirm')));
  await tester.pumpAndSettle();
  expect(gateway.adminActive, isTrue);
  await _reveal(tester, admin);
  await _capture(tester, boundary, '26-protection-on');
  gateway.restoreError = 'Один из будильников не удалось назначить повторно.';
  await controller.refreshStatus();
  await tester.pumpAndSettle();
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('alarm-recovery-retry')).hitTestable(),
    findsOneWidget,
  );
  await _capture(tester, boundary, '27-recovery-error');
  await tester.pumpWidget(const SizedBox.shrink());
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
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
