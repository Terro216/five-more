import 'dart:convert';

import 'package:five_more/app/theme.dart';
import 'package:five_more/features/sync/sync_screen.dart';
import 'package:five_more/services/sync_service.dart';
import 'package:five_more/services/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final width in [390.0, 320.0]) {
    testWidgets(
      'account ID copy and confirmed logout preserve local data at $width',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'five_more_sync_session': jsonEncode({
            'endpoint': 'https://sync.example.test',
            'token': 'test-session',
            'accountId': 'synthetic-account-for-ui-check',
            'sessionId': 'test-session-id',
          }),
        });
        var revocations = 0;
        String? clipboard;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        final sync = SyncService(
          clientFactory: () => MockClient((request) async {
            if (request.method == 'DELETE') {
              revocations++;
            }
            return http.Response(
              jsonEncode({'audioAllowed': false, 'sessions': []}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(sync.dispose);
        sync.setAlarmRinging(false);
        await tester.runAsync(() => sync.load(startPolling: false));
        await tester.runAsync(
          () => LocalDatabase.instance.setSetting('alarm_state', {
            'alarms': [
              {'id': 'keep'},
            ],
          }),
        );
        await tester.runAsync(
          () => LocalDatabase.instance.put('event', 'keep', {
            'eventId': 'keep',
            'id': 'a',
            'occurrenceId': 'wake',
            'type': 'dismissed',
            'at': 1,
          }, 1),
        );
        tester.view.physicalSize = Size(width, width == 320 ? 640 : 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: fiveMoreTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: SyncScreen(sync: sync),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> tapText(String text) async {
          final target = find.text(text);
          await tester.scrollUntilVisible(
            target,
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        await tapText('Идентификатор аккаунта');
        await tapText('Скопировать');
        expect(clipboard, 'synthetic-account-for-ui-check');
        expect(revocations, 0);
        await tapText('Выйти на этом телефоне');
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(sync.signedIn, isTrue);
        expect(revocations, 0);
        await tapText('Выйти на этом телефоне');
        await tester.tap(find.text('Выйти'));
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (!sync.signedIn &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(sync.signedIn, isFalse);
        expect(revocations, 1);
        expect(
          (await tester.runAsync(
            () => LocalDatabase.instance.setting('alarm_state'),
          ))!['alarms'],
          [
            {'id': 'keep'},
          ],
        );
        expect(
          await tester.runAsync(() => LocalDatabase.instance.records('event')),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
