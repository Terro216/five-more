import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../models/background_frame.dart';
import '../../widgets/alarm_background.dart';
import '../../widgets/framed_photo.dart';

class BackgroundEditor extends StatefulWidget {
  const BackgroundEditor({
    super.key,
    required this.name,
    this.initial = const BackgroundFrame(),
  });
  final String name;
  final BackgroundFrame initial;
  @override
  State<BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<BackgroundEditor> {
  late BackgroundFrame _frame = widget.initial;
  ui.Image? _image;
  bool _loading = true;
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
    appBar: AppBar(title: const Text('Кадр фона')),
    body: SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _image == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Не удалось открыть фото. Вернись и выбери другое.',
                ),
              ),
            )
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Text(
                    'Перемещай фото и меняй масштаб двумя пальцами.',
                    textAlign: TextAlign.center,
                  ),
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
                                  label: 'Положение фото',
                                  value:
                                      'Масштаб ${_frame.zoom.toStringAsFixed(1)}',
                                  increasedValue:
                                      'Масштаб ${(_frame.zoom + .25).clamp(1, 4).toStringAsFixed(1)}',
                                  decreasedValue:
                                      'Масштаб ${(_frame.zoom - .25).clamp(1, 4).toStringAsFixed(1)}',
                                  onIncrease: () => _zoom(_frame.zoom + .25),
                                  onDecrease: () => _zoom(_frame.zoom - .25),
                                  customSemanticsActions: {
                                    const CustomSemanticsAction(
                                      label: 'Сдвинуть влево',
                                    ): () =>
                                        _move(const Offset(-24, 0)),
                                    const CustomSemanticsAction(
                                      label: 'Сдвинуть вправо',
                                    ): () =>
                                        _move(const Offset(24, 0)),
                                    const CustomSemanticsAction(
                                      label: 'Сдвинуть вверх',
                                    ): () =>
                                        _move(const Offset(0, -24)),
                                    const CustomSemanticsAction(
                                      label: 'Сдвинуть вниз',
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
                                    child: FramedPhoto(
                                      image: _image!,
                                      frame: _frame,
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
                        tooltip: 'Уменьшить фото',
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
                          label: '${_frame.zoom.toStringAsFixed(1)}×',
                          onChanged: _zoom,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Увеличить фото',
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
                      label: const Text('Повернуть'),
                    ),
                    TextButton(
                      key: const ValueKey('background-reset'),
                      onPressed: () =>
                          setState(() => _frame = const BackgroundFrame()),
                      child: const Text('Сбросить'),
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
                      child: const Text('Применить'),
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}
