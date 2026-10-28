import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';

String clockLabel(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
String remainingLabel(DateTime at, DateTime now) {
  final minutes = max(0, (at.difference(now).inSeconds / 60).ceil());
  return '${minutes ~/ 60} ч ${minutes % 60} мин';
}

/// Typing, wheel/vertical drag and the dial all edit the same value.
class TimeComposer extends StatefulWidget {
  const TimeComposer({
    super.key,
    required this.time,
    required this.onChanged,
    this.enabled = true,
    this.onValidityChanged,
  });
  final TimeOfDay time;
  final ValueChanged<TimeOfDay> onChanged;
  final bool enabled;
  final ValueChanged<bool>? onValidityChanged;
  @override
  State<TimeComposer> createState() => _TimeComposerState();
}

class _TimeComposerState extends State<TimeComposer> {
  bool _minutes = false;
  late final _hour = TextEditingController(
    text: widget.time.hour.toString().padLeft(2, '0'),
  );
  late final _minute = TextEditingController(
    text: widget.time.minute.toString().padLeft(2, '0'),
  );
  double _drag = 0;
  final _hourFocus = FocusNode();
  final _minuteFocus = FocusNode();
  @override
  void didUpdateWidget(TimeComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      if (int.tryParse(_hour.text) != widget.time.hour) {
        _hour.text = widget.time.hour.toString().padLeft(2, '0');
      }
      if (int.tryParse(_minute.text) != widget.time.minute) {
        _minute.text = widget.time.minute.toString().padLeft(2, '0');
      }
    }
  }

  @override
  void dispose() {
    _hour.dispose();
    _minute.dispose();
    _hourFocus.dispose();
    _minuteFocus.dispose();
    super.dispose();
  }

  bool get _valid =>
      int.tryParse(_hour.text) != null &&
      int.parse(_hour.text) < 24 &&
      int.tryParse(_minute.text) != null &&
      int.parse(_minute.text) < 60;
  void _setTime(TimeOfDay time) {
    setState(() {
      _hour.text = time.hour.toString().padLeft(2, '0');
      _minute.text = time.minute.toString().padLeft(2, '0');
    });
    widget.onValidityChanged?.call(true);
    widget.onChanged(time);
  }

  void _step(bool minutes, int delta) {
    if (!widget.enabled) return;
    _setTime(
      minutes
          ? widget.time.replacing(minute: (widget.time.minute + delta) % 60)
          : widget.time.replacing(hour: (widget.time.hour + delta) % 24),
    );
  }

  Widget _input(bool minutes) => Expanded(
    child: Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && widget.enabled) {
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            (_) => _step(minutes, event.scrollDelta.dy > 0 ? -1 : 1),
          );
        }
      },
      child: GestureDetector(
        onVerticalDragStart: (_) => _drag = 0,
        onVerticalDragUpdate: (event) {
          _drag += event.delta.dy;
          if (_drag.abs() >= 12) {
            _step(minutes, _drag > 0 ? -1 : 1);
            _drag = 0;
          }
        },
        child: TextField(
          key: ValueKey(minutes ? 'time-minute-input' : 'time-hour-input'),
          controller: minutes ? _minute : _hour,
          focusNode: minutes ? _minuteFocus : _hourFocus,
          enabled: widget.enabled,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          textInputAction: minutes
              ? TextInputAction.done
              : TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(2),
          ],
          style: const TextStyle(fontSize: 36, color: morning),
          decoration: InputDecoration(
            labelText: minutes ? 'Минуты' : 'Часы',
            errorText:
                (int.tryParse((minutes ? _minute : _hour).text) ?? 99) >=
                    (minutes ? 60 : 24)
                ? (minutes ? '00–59' : '00–23')
                : null,
          ),
          onTap: () => setState(() => _minutes = minutes),
          onChanged: (text) {
            setState(() {});
            widget.onValidityChanged?.call(_valid);
            final value = int.tryParse(text);
            if (value != null && value < (minutes ? 60 : 24)) {
              widget.onChanged(
                minutes
                    ? widget.time.replacing(minute: value)
                    : widget.time.replacing(hour: value),
              );
              if (!minutes && text.length == 2) {
                setState(() => _minutes = true);
                _minuteFocus.requestFocus();
              }
            }
          },
          onEditingComplete: () {
            _setTime(widget.time);
            if (minutes) {
              FocusScope.of(context).unfocus();
            } else {
              setState(() => _minutes = true);
              _minuteFocus.requestFocus();
            }
          },
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          _input(false),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text(':', style: TextStyle(fontSize: 32)),
          ),
          _input(true),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Введи время или прокрути цифры вверх / вниз',
        style: TextStyle(color: muted, fontSize: 12),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Часы'),
            selected: !_minutes,
            onSelected: widget.enabled
                ? (_) => setState(() => _minutes = false)
                : null,
          ),
          ChoiceChip(
            label: const Text('Минуты'),
            selected: _minutes,
            onSelected: widget.enabled
                ? (_) => setState(() => _minutes = true)
                : null,
          ),
        ],
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final size = min(264.0, constraints.maxWidth);
          void select(Offset point) {
            if (!widget.enabled) return;
            final vector = point - Offset(size / 2, size / 2);
            final angle =
                (atan2(vector.dy, vector.dx) + pi / 2 + pi * 2) % (pi * 2);
            if (_minutes) {
              _setTime(
                widget.time.replacing(
                  minute: (angle / (2 * pi) * 60).round() % 60,
                ),
              );
            } else {
              final hour = (angle / (2 * pi) * 12).round() % 12;
              _setTime(
                widget.time.replacing(
                  hour: hour + (vector.distance < size * .31 ? 12 : 0),
                ),
              );
            }
          }

          return Semantics(
            label: _minutes ? 'Циферблат минут' : 'Циферблат 24 часа',
            child: GestureDetector(
              key: const ValueKey('time-dial'),
              onTapUp: (e) {
                if (!widget.enabled) return;
                FocusScope.of(context).unfocus();
                select(e.localPosition);
                if (!_minutes) setState(() => _minutes = true);
              },
              onPanStart: (e) {
                if (!widget.enabled) return;
                FocusScope.of(context).unfocus();
                select(e.localPosition);
              },
              onPanUpdate: (e) => select(e.localPosition),
              onPanEnd: (_) {
                if (widget.enabled && !_minutes) {
                  setState(() => _minutes = true);
                }
              },
              child: CustomPaint(
                size: Size.square(size),
                painter: _ClockPainter(
                  widget.time,
                  _minutes,
                  MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.3),
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}

class _ClockPainter extends CustomPainter {
  _ClockPainter(this.time, this.minutes, this.scale);
  final TimeOfDay time;
  final bool minutes;
  final double scale;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(center, size.width / 2, Paint()..color = panel);
    final selected = minutes ? time.minute / 5 : time.hour % 12;
    final radius = size.width * (!minutes && time.hour >= 12 ? .24 : .40);
    final angle = selected * pi / 6 - pi / 2;
    final tip = center + Offset(cos(angle), sin(angle)) * radius;
    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = morning
        ..strokeWidth = 2,
    );
    canvas.drawCircle(tip, 20, Paint()..color = morning);
    canvas.drawCircle(center, 4, Paint()..color = morning);
    for (var ring = 0; ring < (minutes ? 1 : 2); ring++) {
      for (var i = 0; i < 12; i++) {
        final value = minutes ? i * 5 : i + ring * 12;
        final chosen = minutes ? time.minute == value : time.hour == value;
        final a = i * pi / 6 - pi / 2;
        final position =
            center +
            Offset(cos(a), sin(a)) * size.width * (ring == 0 ? .4 : .24);
        final text = TextPainter(
          text: TextSpan(
            text: '$value'.padLeft(2, '0'),
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: (ring == 0 ? 17 : 14) * scale,
              color: chosen ? ink : foreground,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, position - Offset(text.width / 2, text.height / 2));
        text.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_ClockPainter old) =>
      old.time != time || old.minutes != minutes || old.scale != scale;
}

Future<TimeOfDay?> editClock(
  BuildContext context,
  TimeOfDay initial, {
  String title = 'Время подъёма',
  DateTime Function(TimeOfDay)? nextAt,
  DateTime Function()? now,
}) => showModalBottomSheet<TimeOfDay>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _ClockSheet(
    initial: initial,
    title: title,
    nextAt: nextAt,
    now: now ?? DateTime.now,
  ),
);

class _ClockSheet extends StatefulWidget {
  const _ClockSheet({
    required this.initial,
    required this.title,
    required this.now,
    this.nextAt,
  });
  final TimeOfDay initial;
  final String title;
  final DateTime Function(TimeOfDay)? nextAt;
  final DateTime Function() now;
  @override
  State<_ClockSheet> createState() => _ClockSheetState();
}

class _ClockSheetState extends State<_ClockSheet> {
  late TimeOfDay _time = widget.initial;
  Timer? _ticker;
  bool _valid = true;
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      24,
      20,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (widget.nextAt != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'До звонка ${remainingLabel(widget.nextAt!(_time), widget.now())}',
                  key: const ValueKey('time-remaining'),
                  style: const TextStyle(color: morning),
                ),
              ),
            TimeComposer(
              time: _time,
              onValidityChanged: (valid) => setState(() => _valid = valid),
              onChanged: (value) => setState(() => _time = value),
            ),
            FilledButton(
              onPressed: _valid ? () => Navigator.pop(context, _time) : null,
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    ),
  );
}
