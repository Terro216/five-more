import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../app/theme.dart';
import 'challenge_models.dart';

class QrTask extends StatefulWidget {
  const QrTask({
    super.key,
    this.expected,
    required this.onMatched,
    this.onMistake,
  });
  final String? expected;
  final ValueChanged<String> onMatched;
  final VoidCallback? onMistake;
  @override
  State<QrTask> createState() => _QrTaskState();
}

class _QrTaskState extends State<QrTask> with WidgetsBindingObserver {
  final _camera = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    autoStart: false,
  );
  bool _started = false, _done = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _start() async {
    setState(() {
      _started = true;
      _error = null;
    });
    // Wait until the platform view has mounted.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _camera.start();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Камера недоступна. Разреши камеру в настройках телефона и попробуй снова.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started || _done) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_resume());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_stop());
    }
  }

  Future<void> _stop() async {
    try {
      await _camera.stop();
    } catch (_) {
      /* Camera can already be closed by the OS. */
    }
  }

  Future<void> _resume() async {
    try {
      await _camera.start();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Не удалось включить камеру. Попробуй снова.');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        widget.expected == null
            ? 'Выбери QR-код в месте, до которого нужно дойти утром.'
            : 'Дойди до своего QR-кода и наведи камеру.',
        style: const TextStyle(color: muted, height: 1.5),
      ),
      const SizedBox(height: 16),
      if (kIsWeb)
        const Text(
          'Камера и проверка зарегистрированного QR доступны в приложении на телефоне.',
        )
      else if (!_started)
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text('Открыть камеру'),
        )
      else
        SizedBox(
          height: 280,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: MobileScanner(
              controller: _camera,
              errorBuilder: (context, error) => Center(
                child: Text(
                  'Камера недоступна. Проверь разрешение.\n${error.errorCode.name}',
                  textAlign: TextAlign.center,
                ),
              ),
              onDetect: (capture) {
                if (_done) return;
                final value = capture.barcodes
                    .map((b) => b.rawValue)
                    .whereType<String>()
                    .where((v) => v.isNotEmpty && v.length <= 2048)
                    .firstOrNull;
                if (value == null) return;
                if (widget.expected == null || value == widget.expected) {
                  _done = true;
                  unawaited(_stop());
                  widget.onMatched(value);
                } else {
                  if (widget.onMistake != null) {
                    _done = true;
                    unawaited(_stop());
                    widget.onMistake!();
                    return;
                  }
                  setState(
                    () => _error = 'Это другой QR-код. Найди тот, который зарегистрирован.',
                  );
                }
              },
            ),
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_started && !_done)
        TextButton(
          onPressed: _resume,
          child: const Text('Повторить запуск камеры'),
        ),
    ],
  );
}

Future<String?> registerQr(BuildContext context) => Navigator.push<String>(
  context,
  MaterialPageRoute(
    builder: (context) => Scaffold(
      appBar: AppBar(title: const Text('Зарегистрировать QR-код')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: QrTask(onMatched: (code) => Navigator.pop(context, code)),
      ),
    ),
  ),
);

class ShakeCounter {
  ShakeCounter(this.target);
  final int target;
  int count = 0;
  int _direction = 0;
  Duration? _last;
  bool add(double x, double y, double z, Duration elapsed) {
    if (count >= target) return true;
    final axes = [x, y, z]..sort((a, b) => b.abs().compareTo(a.abs()));
    final peak = axes.first;
    if (!peak.isFinite || peak.abs() < 9) return false;
    if (_last != null && elapsed - _last! < const Duration(milliseconds: 160)) {
      return false;
    }
    final direction = peak >= 0 ? 1 : -1;
    if (direction == _direction) return false;
    if (_last != null && elapsed - _last! > const Duration(seconds: 2)) {
      count = max(0, count - 3);
    }
    _last = elapsed;
    _direction = direction;
    count++;
    return count >= target;
  }
}

class ShakeTask extends StatefulWidget {
  const ShakeTask({
    super.key,
    required this.difficulty,
    required this.onComplete,
  });
  final ChallengeDifficulty difficulty;
  final VoidCallback onComplete;
  @override
  State<ShakeTask> createState() => _ShakeTaskState();
}

class _ShakeTaskState extends State<ShakeTask> with WidgetsBindingObserver {
  late final _counter = ShakeCounter([12, 20, 32, 48][widget.difficulty.index]);
  final _clock = Stopwatch();
  StreamSubscription<UserAccelerometerEvent>? _subscription;
  String? _error;
  bool _complete = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    if (kIsWeb) {
      _error =
          'Тряска доступна на телефоне. В браузере — только просмотр задания.';
      return;
    }
    _clock.start();
    _subscription =
        userAccelerometerEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen(
          (event) {
            if (!mounted || _complete) return;
            final done = _counter.add(
              event.x,
              event.y,
              event.z,
              _clock.elapsed,
            );
            setState(() {});
            if (done) {
              _complete = true;
              unawaited(_subscription?.cancel());
              widget.onComplete();
            }
          },
          onError: (_) {
            if (mounted) {
              setState(
                () => _error = 'Датчик движения недоступен. Можно воспользоваться аварийной остановкой.',
              );
            }
          },
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _subscription?.resume();
    } else {
      _subscription?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Icon(Icons.vibration_rounded, size: 64, color: morning),
      const SizedBox(height: 24),
      const Text(
        'Разбуди телефон',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      const Text(
        'Держи крепко и встряхивай короткими движениями туда-обратно.',
        style: TextStyle(color: muted),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      Text(
        '${_counter.count} / ${_counter.target}',
        style: const TextStyle(fontSize: 32, color: morning),
      ),
      const SizedBox(height: 12),
      LinearProgressIndicator(value: _counter.count / _counter.target),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
    ],
  );
}

/// Deterministic, bounded physics; walls are swept in small substeps.
class TiltMaze {
  TiltMaze(ChallengeDifficulty difficulty) : level = difficulty.index;
  final int level;
  Offset ball = const Offset(.1, .1), velocity = Offset.zero;
  final start = const Offset(.1, .1), goal = const Offset(.9, .9);
  double get radius => .025;
  List<Rect> get walls => [
    const Rect.fromLTWH(.24, 0, .035, .72),
    const Rect.fromLTWH(.49, .28, .035, .72),
    const Rect.fromLTWH(.74, 0, .035, .72),
  ];
  List<Offset> get holes => [
    const Offset(.38, .72),
    const Offset(.64, .28),
    if (level >= 1) const Offset(.86, .58),
    if (level >= 2) const Offset(.12, .53),
    if (level >= 3) ...[const Offset(.37, .4), const Offset(.62, .6)],
  ];
  void reset() {
    ball = start;
    velocity = Offset.zero;
  }

  bool _blocked(Offset point) =>
      point.dx < radius ||
      point.dy < radius ||
      point.dx > 1 - radius ||
      point.dy > 1 - radius ||
      walls.any((wall) => wall.inflate(radius).contains(point));

  /// -1: fell into a hole, 1: goal, 0: keep going.
  int step(Offset tilt, double seconds) {
    if (!tilt.dx.isFinite || !tilt.dy.isFinite) return 0;
    final dt = seconds.clamp(0.0, .05) / 5;
    for (var i = 0; i < 5; i++) {
      velocity = (velocity + tilt * dt * .8) * .97;
      if (velocity.distance > .65) {
        velocity = velocity / velocity.distance * .65;
      }
      final dx = ball + Offset(velocity.dx * dt, 0);
      if (!_blocked(dx)) {
        ball = dx;
      } else {
        velocity = Offset(-velocity.dx * .15, velocity.dy);
      }
      final dy = ball + Offset(0, velocity.dy * dt);
      if (!_blocked(dy)) {
        ball = dy;
      } else {
        velocity = Offset(velocity.dx, -velocity.dy * .15);
      }
      if (holes.any((hole) => (ball - hole).distance < .032 + level * .003)) {
        reset();
        return -1;
      }
      if ((ball - goal).distance < .045) return 1;
    }
    return 0;
  }
}

class MazeTask extends StatefulWidget {
  const MazeTask({
    super.key,
    required this.difficulty,
    required this.onComplete,
    required this.onMistake,
    this.practice = false,
  });
  final ChallengeDifficulty difficulty;
  final VoidCallback onComplete, onMistake;
  final bool practice;
  @override
  State<MazeTask> createState() => _MazeTaskState();
}

class _MazeTaskState extends State<MazeTask> with WidgetsBindingObserver {
  late final _maze = TiltMaze(widget.difficulty);
  Offset _tilt = Offset.zero, _neutral = Offset.zero;
  StreamSubscription<AccelerometerEvent>? _sensor;
  Timer? _timer;
  bool _active = true, _done = false, _received = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _sensor =
          accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
              .listen(
                (e) {
                  if (!_active) return;
                  final value = Offset(-e.x, e.y);
                  if (!_received) {
                    _neutral = value;
                    _received = true;
                  }
                  _tilt = (value - _neutral) / 4;
                },
                onError: (_) {
                  if (mounted) {
                    setState(
                      () => _error = 'Датчик наклона недоступен. Аварийная остановка остаётся доступна.',
                    );
                  }
                },
              );
    }
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!mounted || !_active || _done) return;
      final result = _maze.step(_tilt, .02);
      setState(() {});
      if (result == 1) {
        _done = true;
        widget.onComplete();
      }
      if (result == -1) widget.onMistake();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _tilt = Offset.zero;
      _maze.velocity = Offset.zero;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_sensor?.cancel());
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text(
        'Проведи шарик к финишу',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        kIsWeb
            ? 'Предпросмотр: веди пальцем по полю. На телефоне управление наклоном.'
            : 'Наклоняй телефон. Отверстие вернёт на предыдущий этап.',
        style: const TextStyle(color: muted),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onPanUpdate: kIsWeb && widget.practice
                ? (e) {
                    _tilt =
                        (e.localPosition / constraints.maxWidth -
                            const Offset(.5, .5)) *
                        3;
                  }
                : null,
            onPanEnd: (_) => _tilt = Offset.zero,
            child: CustomPaint(painter: _MazePainter(_maze)),
          ),
        ),
      ),
      if (_error != null) Text(_error!),
      TextButton(
        onPressed: () {
          _neutral += _tilt * 4;
          _tilt = Offset.zero;
          _maze.velocity = Offset.zero;
        },
        child: const Text('Этот наклон — нейтральный'),
      ),
    ],
  );
}

class _MazePainter extends CustomPainter {
  _MazePainter(this.maze);
  final TiltMaze maze;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      Paint()..color = panel,
    );
    for (final wall in maze.walls) {
      canvas.drawRect(
        Rect.fromLTRB(
          wall.left * size.width,
          wall.top * size.height,
          wall.right * size.width,
          wall.bottom * size.height,
        ),
        Paint()..color = muted,
      );
    }
    for (final hole in maze.holes) {
      canvas.drawCircle(
        Offset(hole.dx * size.width, hole.dy * size.height),
        (.032 + maze.level * .003) * size.width,
        Paint()..color = Colors.black,
      );
    }
    canvas.drawCircle(
      Offset(maze.goal.dx * size.width, maze.goal.dy * size.height),
      .05 * size.width,
      Paint()..color = const Color(0xFF8EDDAB),
    );
    canvas.drawCircle(
      Offset(maze.ball.dx * size.width, maze.ball.dy * size.height),
      maze.radius * size.width,
      Paint()..color = morning,
    );
  }

  @override
  bool shouldRepaint(_MazePainter old) => true;
}
