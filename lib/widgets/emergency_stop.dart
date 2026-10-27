import 'dart:async';

import 'package:flutter/material.dart';

import '../app/theme.dart';

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
  Timer? _timer;
  double _progress = 0;
  bool _acknowledged = false;
  bool _accessibleReady = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _cancel() {
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _progress = 0;
        _accessibleReady = false;
      });
    }
  }

  void _start() {
    if (!_acknowledged) return;
    _cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) return;
      setState(() => _progress = (timer.tick / 100).clamp(0, 1));
      if (_progress >= 1) {
        _timer?.cancel();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Нужна помощь с остановкой?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Если задание выполнить не получается, звонок можно остановить здесь. Этот подъём попадёт в историю как аварийное отключение.',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Остановить без пройденного задания'),
          value: _acknowledged,
          onChanged: (v) {
            _cancel();
            setState(() => _acknowledged = v ?? false);
          },
        ),
        const SizedBox(height: 12),
        if (MediaQuery.accessibleNavigationOf(context))
          OutlinedButton(
            onPressed: !_acknowledged
                ? null
                : _accessibleReady
                ? () => Navigator.pop(context, true)
                : _start,
            child: Text(
              _accessibleReady
                  ? 'Подтвердить остановку'
                  : 'Подготовить остановку · 5 секунд',
            ),
          )
        else
          Listener(
            onPointerDown: _acknowledged ? (_) => _start() : null,
            onPointerUp: (_) => _cancel(),
            onPointerCancel: (_) => _cancel(),
            child: Semantics(
              button: true,
              enabled: _acknowledged,
              label: 'Удерживай пять секунд для аварийной остановки',
              child: Container(
                constraints: const BoxConstraints(minHeight: 64),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: panel,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(
                      _progress > 0
                          ? 'Ещё ${(5 * (1 - _progress)).ceil()} сек'
                          : 'Удерживай 5 секунд',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _acknowledged ? foreground : muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Вернуться к заданию'),
      ),
    ],
  );
}
