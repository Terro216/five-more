import 'dart:async';

import 'package:five_more/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  setUpAll(() async {
    final warmup = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await warmup.close();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocalDatabase.instance = LocalDatabase(path: inMemoryDatabasePath);
    await LocalDatabase.instance.database;
  });
  tearDown(() => LocalDatabase.instance.close());
  await testMain();
}
