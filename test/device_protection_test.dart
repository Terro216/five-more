import 'package:five_more/app/alarm_controller.dart';
import 'package:five_more/app/theme.dart';
import 'package:five_more/features/alarms/device_check_screen.dart';
import 'package:five_more/models/alarm.dart';
import 'package:five_more/models/device_alarm_check.dart';
import 'package:five_more/services/alarm_gateway.dart';
import 'package:five_more/services/alarm_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'alarm_fakes.dart';

const _source = Alarm(
  id: 'real-morning',
  hour: 7,
  minute: 30,
  weekdays: [1, 2, 3, 4, 5],
  moveSnoozeButton: true,
);

class _ProtectionGateway extends FakeAlarmGateway {
  String platform = 'android';
  bool? adminActive = false;
  bool? bootSupported = true;
  bool? batteryOptimized = true;
  String? recoveryError;
  bool rejectRestore = false;
  bool keepRecoveryErrorOnSuccess = false;
  int restoreCalls = 0;
  DeviceAlarmCheck? activeTest;
  final permissionTargets = <String?>[];

  @override
  Future<AlarmDeviceStatus> status() async => AlarmDeviceStatus(
    platform: platform,
    supported: supported,
    exactAlarms: supported,
    notifications: supported,
    fullScreenIntent: supported,
    challengeEnforced: platform != 'ios',
    alarms: nativeAlarms.values.toList(),
    deviceAdminActive: adminActive,
    bootRecoverySupported: bootSupported,
    batteryOptimized: batteryOptimized,
    recoveryError: recoveryError,
    activeTest: activeTest,
  );

  @override
  Future<void> requestPermissions({String? target}) async {
    permissionTargets.add(target);
    // Opening the native system request does not prove that the user accepted
    // it. Activation and removal are reported independently by status().
  }

  @override
  Future<AlarmResult> restoreAlarms() async {
    restoreCalls++;
    if (rejectRestore) {
      return AlarmResult(
        ok: false,
        error: recoveryError ?? 'Не удалось восстановить расписание.',
      );
    }
    if (!keepRecoveryErrorOnSuccess) recoveryError = null;
    return const AlarmResult(ok: true);
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));

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
  expect(finder.hitTestable(), findsOneWidget);
}

Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  double delta = 220,
}) async {
  await _reveal(tester, finder, delta: delta);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _expandProtection(WidgetTester tester) async {
  await _tap(tester, find.text('Надёжность и защита'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({AlarmController controller, MemoryAlarmStorage storage})> showScreen(
    WidgetTester tester,
    _ProtectionGateway gateway, {
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    gateway.nativeAlarms[_source.id] = _source;
    final storage = MemoryAlarmStorage()
      ..snapshot = AlarmSnapshot(
        alarms: const [_source],
        deviceCheck: gateway.activeTest,
      );
    final controller = AlarmController(
      gateway: gateway,
      storage: storage,
      now: () => DateTime(2026, 10, 23, 7, 20),
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
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: DeviceCheckScreen(
          controller: controller,
          sourceAlarmId: _source.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller: controller, storage: storage);
  }

  test(
    'optional protection status parses real booleans without guessing support',
    () {
      for (final value in [null, true, false, 'true', 1, <String, Object>{}]) {
        final status = AlarmDeviceStatus.fromJson({
          'platform': 'android',
          'supported': true,
          'exactAlarms': true,
          'notifications': true,
          'fullScreenIntent': true,
          'deviceAdminActive': value,
          'bootRecoverySupported': value,
        });
        final expected = value is bool ? value : null;
        expect(status.deviceAdminActive, expected);
        expect(status.bootRecoverySupported, expected);
        expect(status.canSchedule, isTrue);
        expect(
          status.needsAttention,
          isFalse,
          reason: 'Optional protection is not a mandatory alarm permission.',
        );
      }
      final legacy = AlarmDeviceStatus.fromJson({'supported': true});
      expect(legacy.deviceAdminActive, isNull);
      expect(legacy.bootRecoverySupported, isNull);
    },
  );

  test('recovery failures request attention without pretending scheduling is forbidden', () {
    final status = AlarmDeviceStatus.fromJson({
      'platform': 'android',
      'supported': true,
      'exactAlarms': true,
      'notifications': true,
      'fullScreenIntent': true,
      'deviceAdminActive': false,
      'bootRecoverySupported': true,
      'recoveryError': 'schedule_failed',
    });
    expect(status.needsAttention, isTrue);
    expect(status.canSchedule, isTrue);
    expect(status.recoveryError, alarmErrorMessage('schedule_failed'));
    expect(status.error, isNull);
  });

  test(
    'the native restore action has its own method and reports failure',
    () async {
      const channel = MethodChannel('five_more/alarm');
      final calls = <MethodCall>[];
      var fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return fail
                ? {'ok': false, 'error': 'schedule_failed'}
                : {'ok': true};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final gateway = NativeAlarmGateway();
      final failed = await gateway.restoreAlarms();
      expect(failed.ok, isFalse);
      expect(failed.error, alarmErrorMessage('schedule_failed'));
      fail = false;
      expect((await gateway.restoreAlarms()).ok, isTrue);
      expect(calls.map((call) => call.method), [
        'restoreAlarms',
        'restoreAlarms',
      ]);
      expect(
        calls.every(
          (call) => call.arguments is Map && (call.arguments as Map).isEmpty,
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'admin activation and removal require confirmation and actual native status',
    (tester) async {
      final gateway = _ProtectionGateway();
      final state = await showScreen(tester, gateway);
      expect(gateway.permissionTargets, isEmpty);
      expect(gateway.restoreCalls, 0);
      await _expandProtection(tester);
      expect(gateway.permissionTargets, isEmpty);
      final change = _key('device-admin-change');
      await _tap(tester, change);
      expect(find.text('Защитить от удаления?'), findsOneWidget);
      expect(gateway.permissionTargets, isEmpty);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(gateway.permissionTargets, isEmpty);

      await _tap(tester, change);
      await tester.tap(_key('device-admin-confirm'));
      await tester.pumpAndSettle();
      expect(gateway.permissionTargets, ['deviceAdmin']);
      expect(state.controller.device.deviceAdminActive, isFalse);
      expect(
        tester.widget<Text>(_key('device-admin-status')).data,
        contains('Дополнительный шаг'),
      );
      expect(find.text('Включить защиту от удаления'), findsOneWidget);

      gateway.adminActive = true;
      await state.controller.refreshStatus();
      await tester.pumpAndSettle();
      await _reveal(tester, change);
      expect(
        tester.widget<Text>(_key('device-admin-status')).data,
        contains('Статус администратора включён'),
      );
      expect(find.text('Снять защиту от удаления'), findsOneWidget);
      await tester.tap(change);
      await tester.pumpAndSettle();
      expect(find.text('Снять защиту от удаления?'), findsOneWidget);
      await tester.tap(_key('device-admin-confirm'));
      await tester.pumpAndSettle();
      expect(gateway.permissionTargets, ['deviceAdmin', 'removeDeviceAdmin']);
      expect(
        state.controller.device.deviceAdminActive,
        isTrue,
        reason: 'An asynchronous native removal may not have finished yet.',
      );
      expect(find.text('Снять защиту от удаления'), findsOneWidget);
      gateway.adminActive = false;
      await state.controller.refreshStatus();
      // Android may finish removeActiveAdmin after the request returns. Allow
      // the bounded status refresh in the screen to observe that final result.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Включить защиту от удаления'), findsOneWidget);
      expect(gateway.scheduleCalls, isEmpty);
      expect(gateway.cancelCalls, isEmpty);
      expect(state.storage.snapshot.alarms.single.toJson(), _source.toJson());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final platform in ['ios', 'preview']) {
    testWidgets('$platform does not expose Android protection actions', (
      tester,
    ) async {
      final gateway = _ProtectionGateway()
        ..platform = platform
        ..supported = platform != 'preview';
      final state = await showScreen(tester, gateway);
      expect(_key('device-reliability'), findsNothing);
      expect(_key('device-admin-change'), findsNothing);
      expect(_key('alarm-recovery-manual'), findsNothing);
      expect(gateway.permissionTargets, isEmpty);
      if (platform == 'preview') {
        expect((await state.controller.restoreAlarms()).ok, isFalse);
        expect(gateway.restoreCalls, 0);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'unknown Android support cannot offer admin or manual recovery actions',
    (tester) async {
      final gateway = _ProtectionGateway()
        ..adminActive = null
        ..bootSupported = null;
      final state = await showScreen(tester, gateway);
      await _expandProtection(tester);
      await _reveal(tester, _key('device-admin-status'));
      expect(
        tester.widget<Text>(_key('device-admin-status')).data,
        contains('недоступен'),
      );
      expect(_key('device-admin-change'), findsNothing);
      expect(_key('alarm-recovery-manual'), findsNothing);
      expect((await state.controller.restoreAlarms()).ok, isFalse);
      expect(gateway.restoreCalls, 0);
      expect(gateway.permissionTargets, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recovery retries remain usable and never confirm an unheard test',
    (tester) async {
      final check = DeviceAlarmCheck(
        sourceAlarmId: _source.id,
        previewAlarmId: 'preview:waiting',
        startedAt: DateTime(2026, 10, 23, 7, 20),
        dueAt: DateTime(2026, 10, 23, 7, 20, 20),
      );
      final gateway = _ProtectionGateway()
        ..activeTest = check
        ..recoveryError = List.filled(
          5,
          'Не все звонки восстановлены. Проверь системное разрешение.',
        ).join(' ')
        ..rejectRestore = true;
      final state = await showScreen(
        tester,
        gateway,
        width: 320,
        textScale: 1.5,
      );
      expect(_key('alarm-recovery-error'), findsOneWidget);
      await _tap(tester, _key('alarm-recovery-retry'));
      expect(gateway.restoreCalls, 1);
      expect(state.controller.device.recoveryError, isNotNull);
      expect(_key('alarm-recovery-error'), findsOneWidget);
      expect(state.controller.deviceCheck?.heard, isNull);
      expect(state.storage.snapshot.deviceCheck?.confirmedAt, isNull);
      gateway.rejectRestore = false;
      await _tap(tester, _key('alarm-recovery-retry'));
      expect(gateway.restoreCalls, 2);
      expect(state.controller.device.recoveryError, isNull);
      expect(_key('alarm-recovery-error'), findsNothing);
      expect(_key('alarm-recovery-retry'), findsNothing);
      expect(
        find.text('Расписание восстановлено. Проверь звонок на телефоне.'),
        findsOneWidget,
      );
      expect(state.controller.deviceCheck?.toJson(), check.toJson());
      expect(state.storage.snapshot.deviceCheck?.toJson(), check.toJson());
      expect(state.controller.alarms.single.toJson(), _source.toJson());
      expect(gateway.nativeAlarms[_source.id]?.toJson(), _source.toJson());
      expect(gateway.scheduleCalls, isEmpty);
      expect(gateway.cancelCalls, isEmpty);
      expect(gateway.snoozeCalls, isEmpty);
      expect(gateway.dismissCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'narrow large-text protection keeps separate settings and manual recovery reachable',
    (tester) async {
      final gateway = _ProtectionGateway();
      final state = await showScreen(
        tester,
        gateway,
        width: 320,
        textScale: 1.5,
      );
      await _expandProtection(tester);
      await _tap(tester, find.text('Разрешить работу без оптимизации'));
      expect(gateway.permissionTargets, ['battery']);
      await _tap(tester, _key('device-app-settings'));
      expect(gateway.permissionTargets, ['battery', 'appSettings']);
      await _tap(tester, _key('device-admin-change'));
      expect(_key('device-admin-confirm').hitTestable(), findsOneWidget);
      expect(find.text('Отмена').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(gateway.permissionTargets, ['battery', 'appSettings']);
      await _tap(tester, _key('alarm-recovery-manual'));
      expect(gateway.restoreCalls, 1);
      expect(
        find.text('Расписание восстановлено. Проверь звонок на телефоне.'),
        findsOneWidget,
      );
      expect(state.controller.deviceCheck, isNull);
      expect(state.storage.snapshot.deviceCheck, isNull);
      expect(gateway.scheduleCalls, isEmpty);
      expect(gateway.cancelCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native restore success is not enough while status still reports a recovery failure',
    (tester) async {
      final gateway = _ProtectionGateway()
        ..recoveryError = 'Часть системных будильников ещё не восстановлена.'
        ..keepRecoveryErrorOnSuccess = true;
      final state = await showScreen(tester, gateway);
      await _tap(tester, _key('alarm-recovery-retry'));
      expect(gateway.restoreCalls, 1);
      expect(state.controller.device.recoveryError, isNotNull);
      expect(state.controller.error, isNotNull);
      expect(_key('alarm-recovery-error'), findsOneWidget);
      expect(
        find.text('Расписание восстановлено. Проверь звонок на телефоне.'),
        findsNothing,
      );
      expect(state.controller.deviceCheck, isNull);
      expect(gateway.scheduleCalls, isEmpty);

      gateway.keepRecoveryErrorOnSuccess = false;
      await _tap(tester, _key('alarm-recovery-retry'));
      expect(gateway.restoreCalls, 2);
      expect(state.controller.device.recoveryError, isNull);
      expect(_key('alarm-recovery-error'), findsNothing);
      expect(
        find.text('Расписание восстановлено. Проверь звонок на телефоне.'),
        findsOneWidget,
      );
      expect(state.controller.deviceCheck, isNull);
      expect(state.controller.alarms.single.toJson(), _source.toJson());
      expect(gateway.scheduleCalls, isEmpty);
      expect(gateway.cancelCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
