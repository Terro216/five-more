import 'dart:async';

import 'package:flutter/material.dart';

import '../features/alarms/alarm_home.dart';
import '../features/alarms/ringing_screen.dart';
import '../l10n/strings.dart';
import '../l10n/web_language_stub.dart'
    if (dart.library.js_interop) '../l10n/web_language.dart';
import '../services/appearance_settings.dart';
import '../services/sync_service.dart';
import 'alarm_controller.dart';
import 'theme.dart';

class FiveMoreApp extends StatefulWidget {
  const FiveMoreApp({super.key, required this.controller});
  final AlarmController controller;

  @override
  State<FiveMoreApp> createState() => _FiveMoreAppState();
}

class _FiveMoreAppState extends State<FiveMoreApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller.loading) unawaited(widget.controller.initialize());
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    _refreshLanguage();
  }

  void _refreshLanguage() {
    unawaited(AppLanguage.instance.load().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    SyncService.instance.setForeground(false);
    if (state == AppLifecycleState.resumed) {
      _refreshLanguage();
      unawaited(
        widget.controller.refreshStatus().then(
          (_) => SyncService.instance.setForeground(true),
        ),
      );
    }
    if (state == AppLifecycleState.resumed) {
      widget.controller.setForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.controller.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      AppearanceSettings.instance,
      AppLanguage.instance,
    ]),
    builder: (context, _) => MaterialApp(
      onGenerateTitle: (context) {
        updateWebLanguage(context.strings.localeName);
        return context.strings.appName;
      },
      debugShowCheckedModeBanner: false,
      theme: fiveMoreTheme(brightness: Brightness.light),
      darkTheme: fiveMoreTheme(),
      themeMode: AppearanceSettings.instance.mode,
      locale: AppLanguage.instance.value,
      localeListResolutionCallback: (locales, _) =>
          AppLanguage.instance.resolve(locales),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AlarmHome(controller: widget.controller),
      builder: (context, child) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final ringing = widget.controller.ringing;
          // Above the Navigator so an open editor cannot cover an actual alarm.
          return Stack(
            children: [
              ?child,
              if (ringing != null)
                Positioned.fill(
                  child: HeroControllerScope.none(
                    child: Navigator(
                      key: ValueKey(
                        'ring:${ringing.occurrenceId}:${ringing.snoozesUsed}',
                      ),
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => RingingScreen(
                          controller: widget.controller,
                          ringing: ringing,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
