import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../models/alarm.dart';
import '../../models/background_frame.dart';
import '../../widgets/alarm_background.dart';
import '../../widgets/framed_photo.dart';
import '../../widgets/time_composer.dart';

class BackgroundEditor extends StatefulWidget {
  const BackgroundEditor({
    super.key,
    required this.name,
    this.initial = const BackgroundFrame(),
    this.alarm,
  });
  final String name;
  final Alarm? alarm;
  final BackgroundFrame initial;
  @override
  State<BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<BackgroundEditor> {
  late BackgroundFrame _frame = widget.initial;
  ui.Image? _image;
  bool _loading = true;
  bool _showGuide = true;
  Size _viewport = Size.zero;
  Offset _anchor = Offset.zero;
  double _gestureZoom = 1;
  int _pointers = 0;
  Size get _imageSize =>
      Size(_image!.width.toDouble(), _image!.height.toDouble());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ui.Image? image;
    try {
      image = await readBackgroundImage(widget.name);
    } catch (_) {
      /* Show a recoverable local error. */
    }
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _image = image;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _anchorAt(Offset focal, double scale, int pointers) {
    final rect = backgroundRect(_imageSize, _viewport, _frame);
    _anchor = Offset(
      (focal.dx - rect.left) / rect.width,
      (focal.dy - rect.top) / rect.height,
    );
    _gestureZoom = _frame.zoom / scale;
    _pointers = pointers;
  }

  void _scale(ScaleUpdateDetails details) {
    if (details.pointerCount != _pointers) {
      _anchorAt(details.localFocalPoint, details.scale, details.pointerCount);
    }
    final next = _frame.copyWith(zoom: _gestureZoom * details.scale);
    final size = backgroundRect(_imageSize, _viewport, next).size;
    final topLeft =
        details.localFocalPoint -
        Offset(_anchor.dx * size.width, _anchor.dy * size.height);
    setState(
      () => _frame = positionBackground(next, _imageSize, _viewport, topLeft),
    );
  }

  void _zoom(double value) {
    final center = _viewport.center(Offset.zero);
    final rect = backgroundRect(_imageSize, _viewport, _frame);
    final anchor = Offset(
      (center.dx - rect.left) / rect.width,
      (center.dy - rect.top) / rect.height,
    );
    final next = _frame.copyWith(zoom: value);
    final size = backgroundRect(_imageSize, _viewport, next).size;
    setState(
      () => _frame = positionBackground(
        next,
        _imageSize,
        _viewport,
        center - Offset(anchor.dx * size.width, anchor.dy * size.height),
      ),
    );
  }

  void _move(Offset delta) {
    final rect = backgroundRect(_imageSize, _viewport, _frame);
    setState(
      () => _frame = positionBackground(
        _frame,
        _imageSize,
        _viewport,
        rect.topLeft + delta,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.framePhoto)),
    body: SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _image == null
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(context.strings.photoOpenError),
              ),
            )
          : Column(
              children: [
                SwitchListTile.adaptive(
                  title: Text(context.strings.previewAlarmControls),
                  subtitle: Text(context.strings.framePhotoHint),
                  value: _showGuide,
                  onChanged: (value) => setState(() => _showGuide = value),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: MediaQuery.sizeOf(context).aspectRatio,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            _viewport = constraints.biggest;
                            return CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowLeft,
                                ): () =>
                                    _move(const Offset(-24, 0)),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowRight,
                                ): () =>
                                    _move(const Offset(24, 0)),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowUp,
                                ): () =>
                                    _move(const Offset(0, -24)),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowDown,
                                ): () =>
                                    _move(const Offset(0, 24)),
                              },
                              child: Focus(
                                autofocus: true,
                                child: Semantics(
                                  label: context.strings.photoPosition,
                                  value: context.strings.zoom(
                                    appDecimal(_frame.zoom),
                                  ),
                                  increasedValue: context.strings.zoom(
                                    appDecimal((_frame.zoom + .25).clamp(1, 4)),
                                  ),
                                  decreasedValue: context.strings.zoom(
                                    appDecimal((_frame.zoom - .25).clamp(1, 4)),
                                  ),
                                  onIncrease: () => _zoom(_frame.zoom + .25),
                                  onDecrease: () => _zoom(_frame.zoom - .25),
                                  customSemanticsActions: {
                                    CustomSemanticsAction(
                                      label: context.strings.moveLeft,
                                    ): () =>
                                        _move(const Offset(-24, 0)),
                                    CustomSemanticsAction(
                                      label: context.strings.moveRight,
                                    ): () =>
                                        _move(const Offset(24, 0)),
                                    CustomSemanticsAction(
                                      label: context.strings.moveUp,
                                    ): () =>
                                        _move(const Offset(0, -24)),
                                    CustomSemanticsAction(
                                      label: context.strings.moveDown,
                                    ): () =>
                                        _move(const Offset(0, 24)),
                                  },
                                  child: GestureDetector(
                                    key: const ValueKey('background-canvas'),
                                    behavior: HitTestBehavior.opaque,
                                    onScaleStart: (d) => _anchorAt(
                                      d.localFocalPoint,
                                      1,
                                      d.pointerCount,
                                    ),
                                    onScaleUpdate: _scale,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        FramedPhoto(
                                          image: _image!,
                                          frame: _frame,
                                        ),
                                        if (_showGuide)
                                          Positioned.fill(
                                            child: IgnorePointer(
                                              child: ExcludeSemantics(
                                                child: Opacity(
                                                  opacity: .6,
                                                  child: _PhotoGuide(
                                                    alarm: widget.alarm,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: context.strings.zoomOut,
                        onPressed: _frame.zoom > 1
                            ? () => _zoom(_frame.zoom - .25)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('background-zoom'),
                          value: _frame.zoom,
                          min: 1,
                          max: 4,
                          label: '${appDecimal(_frame.zoom)}×',
                          onChanged: _zoom,
                        ),
                      ),
                      IconButton(
                        tooltip: context.strings.zoomIn,
                        onPressed: _frame.zoom < 4
                            ? () => _zoom(_frame.zoom + .25)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('background-rotate'),
                      onPressed: () => setState(
                        () => _frame = _frame.copyWith(
                          turns: (_frame.turns + 1) % 4,
                          x: .5,
                          y: .5,
                        ),
                      ),
                      icon: const Icon(Icons.rotate_right),
                      label: Text(context.strings.rotate),
                    ),
                    TextButton(
                      key: const ValueKey('background-reset'),
                      onPressed: () =>
                          setState(() => _frame = const BackgroundFrame()),
                      child: Text(context.strings.reset),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('background-apply'),
                      onPressed: () => Navigator.of(context).pop(_frame),
                      child: Text(context.strings.apply),
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}

class _PhotoGuide extends StatelessWidget {
  const _PhotoGuide({this.alarm});
  final Alarm? alarm;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(
      width: 390,
      height: 844,
      child: Theme(
        data: ThemeData.dark(),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(context.strings.quieter30S),
                ),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: 350,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.wb_twilight_rounded,
                              color: Colors.white,
                              size: 36,
                            ),
                            const SizedBox(height: 12),
                            Text(context.strings.goodMorning),
                            const SizedBox(height: 12),
                            Text(
                              clockLabel(
                                TimeOfDay(
                                  hour: alarm?.hour ?? 7,
                                  minute: alarm?.minute ?? 0,
                                ),
                              ),
                              style: const TextStyle(
                                fontSize: 96,
                                fontWeight: FontWeight.w300,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (alarm?.displayTitle.isNotEmpty ?? false)
                              Text(
                                alarm!.displayTitle,
                                style: const TextStyle(fontSize: 22),
                                textAlign: TextAlign.center,
                              ),
                            const SizedBox(height: 16),
                            if (alarm?.requiresChallenge ?? true)
                              Text(context.strings.wakeUpChallengeLabel),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                for (final label in [
                  alarm?.requiresChallenge == false
                      ? context.strings.dismiss
                      : context.strings.startChallenge,
                  if (alarm == null || alarm!.snoozeBudget > 0)
                    context.strings.appName,
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(context.strings.troubleWithTheChallenge),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
