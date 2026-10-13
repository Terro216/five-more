import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../features/alarms/alarm_home.dart';
import '../features/alarms/ringing_screen.dart';
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ещё пять',
    debugShowCheckedModeBanner: false,
    theme: fiveMoreTheme(),
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
                    key: ValueKey('ring:${ringing.occurrenceId}'),
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
  );
}
