import 'dart:async';

import 'package:flutter/material.dart';

import 'app/alarm_controller.dart';
import 'app/five_more_app.dart';
import 'services/alarm_gateway.dart';
import 'services/alarm_storage.dart';
import 'services/phrase_library.dart';
import 'services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await PhraseLibrary.instance.load();
  } catch (_) {}
  final controller = AlarmController(
    gateway: NativeAlarmGateway(),
    storage: LocalAlarmStorage(),
  );
  controller.addListener(() {
    final blocked =
        controller.loading ||
        !controller.nativeStateKnown ||
        controller.ringing != null;
    SyncService.instance.setAlarmRinging(blocked);
    PhraseLibrary.instance.setAlarmRinging(blocked);
  });
  runApp(FiveMoreApp(controller: controller));
  unawaited(SyncService.instance.load());
}
