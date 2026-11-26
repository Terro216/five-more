import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import '../l10n/strings.dart';

const emergencyHoldSeconds = 60;

Future<bool> confirmEmergencyStop(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (_) => const _EmergencyStop(),
    ) ??
    false;

class _EmergencyStop extends StatefulWidget {
  const _EmergencyStop();
  @override
  State<_EmergencyStop> createState() => _EmergencyStopState();
}

class _EmergencyStopState extends State<_EmergencyStop>
    with WidgetsBindingObserver {
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  late final String _code;
  final _answer = TextEditingController();
  final _holdKey = GlobalKey();
  Timer? _timer;
  double _progress = 0;
  bool _verified = false;
  bool _accessibleReady = false;
  bool _wrongCode = false;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    final random = Random.secure();
    _code = List.generate(
      12,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
    WidgetsBinding.instance.addObserver(this);
  }

  void _cancel() {
    _timer?.cancel();
    _pointer = null;
    if (mounted) {
      setState(() {
        _progress = 0;
        _accessibleReady = false;
      });
    }
  }

  void _checkCode(String value) {
    final answer = value.toUpperCase();
    setState(() {
      _verified = answer == _code;
      _wrongCode = answer.length == 12 && !_verified;
    });
    if (_verified) FocusScope.of(context).unfocus();
  }

  void _start() {
    if (!_verified || _timer?.isActive == true) return;
    setState(() {
      _progress = 0;
      _accessibleReady = false;
    });
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      setState(
        () =>
            _progress = (timer.tick / (emergencyHoldSeconds * 10)).clamp(0, 1),
      );
      if (_progress >= 1) {
        timer.cancel();
        if (MediaQuery.accessibleNavigationOf(context)) {
          setState(() => _accessibleReady = true);
        } else {
          Navigator.pop(context, true);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: Text(context.strings.emergencyStop),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_verified) ...[
          Text(
            MediaQuery.accessibleNavigationOf(context)
                ? context.strings.emergencyCountdownInstructions
                : context.strings.emergencyHoldInstructions,
          ),
          const SizedBox(height: 16),
          Text(
            '${_code.substring(0, 4)} ${_code.substring(4, 8)} ${_code.substring(8)}',
            key: const ValueKey('emergency-code'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.palette.morning,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('emergency-code-input'),
            controller: _answer,
            autocorrect: false,
            enableSuggestions: false,
            enableInteractiveSelection: false,
            textCapitalization: TextCapitalization.characters,
            keyboardType: TextInputType.visiblePassword,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
              LengthLimitingTextInputFormatter(12),
            ],
            decoration: InputDecoration(
              labelText: context.strings.codeOnScreen,
              errorText: _wrongCode ? context.strings.codeDoesntMatch : null,
            ),
            onChanged: _checkCode,
          ),
        ] else ...[
          Text(
            MediaQuery.accessibleNavigationOf(context)
                ? context.strings.accessibleEmergencyCountdownHint
                : context.strings.emergencyHoldResetHint,
          ),
          const SizedBox(height: 16),
          if (MediaQuery.accessibleNavigationOf(context)) ...[
            OutlinedButton(
              key: const ValueKey('emergency-accessible-confirm'),
              onPressed: _timer?.isActive == true
                  ? null
                  : _accessibleReady
                  ? () => Navigator.pop(context, true)
                  : _start,
              child: Text(
                _accessibleReady
                    ? context.strings.confirmStop
                    : _progress > 0
                    ? context.strings.secondsRemaining(
                        (emergencyHoldSeconds * (1 - _progress)).ceil(),
                      )
                    : context.strings.start60SecondCountdown,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
          ] else
            Listener(
              key: const ValueKey('emergency-hold'),
              onPointerDown: (event) {
                if (_pointer != null) return;
                _pointer = event.pointer;
                _start();
              },
              onPointerMove: (event) {
                final box =
                    _holdKey.currentContext?.findRenderObject() as RenderBox?;
                if (event.pointer == _pointer &&
                    box != null &&
                    !(Offset.zero & box.size).contains(event.localPosition)) {
                  _cancel();
                }
              },
              onPointerUp: (event) {
                if (event.pointer == _pointer) _cancel();
              },
              onPointerCancel: (event) {
                if (event.pointer == _pointer) _cancel();
              },
              child: Semantics(
                button: true,
                label: context.strings.holdFor60SecondsForAnEmergency,
                child: Container(
                  key: _holdKey,
                  constraints: const BoxConstraints(minHeight: 80),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.palette.panel,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _progress > 0
                            ? context.strings.secondsRemaining(
                                (emergencyHoldSeconds * (1 - _progress)).ceil(),
                              )
                            : context.strings.holdForOneMinute,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: _progress),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            context.strings.thisWillBeRecordedAsAnEmergency,
            style: TextStyle(color: context.palette.muted, fontSize: 12),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.strings.backToChallenge),
      ),
    ],
  );
}
