import 'package:flutter/material.dart';

import 'app/alarm_controller.dart';
import 'app/five_more_app.dart';
import 'services/alarm_gateway.dart';
import 'services/alarm_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AlarmController(
    gateway: NativeAlarmGateway(),
    storage: LocalAlarmStorage(),
  );
  runApp(FiveMoreApp(controller: controller));
}
