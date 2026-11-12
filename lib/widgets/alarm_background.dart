import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/alarm.dart';
import '../models/background_frame.dart';
import '../services/native_extras.dart';
import 'framed_photo.dart';

Future<ui.Image?> readBackgroundImage(String name) async {
  if (!validBackgroundName(name)) return null;
  final bytes = await NativeExtras.call<Uint8List>('readBackground', {
    'file': name,
  });
  if (bytes == null || bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
    return null;
  }
  return decodeImageFromList(bytes);
}

/// A missing/locked photo must never obstruct the alarm's controls or sound.
class AlarmBackground extends StatefulWidget {
  const AlarmBackground({
    super.key,
    required this.name,
    required this.child,
    this.frame = const BackgroundFrame(),
  });
  final String name;
  final BackgroundFrame frame;
  final Widget child;
  @override
  State<AlarmBackground> createState() => _AlarmBackgroundState();
}

class _AlarmBackgroundState extends State<AlarmBackground> {
  ui.Image? _image;
  int _loadId = 0;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final id = ++_loadId;
    ui.Image? image;
    try {
      image = await readBackgroundImage(widget.name);
    } catch (_) {
      /* An optional photo must not block alarm controls. */
    }
    if (!mounted || id != _loadId) {
      image?.dispose();
      return;
    }
    setState(() => _image = image);
  }

  void _releaseImage() {
    final old = _image;
    _image = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void didUpdateWidget(AlarmBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _releaseImage();
      _read();
    }
  }

  @override
  void dispose() {
    _loadId++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_image != null) ...[
            FramedPhoto(image: _image!, frame: widget.frame),
            ColoredBox(
              color: theme.scaffoldBackgroundColor.withValues(
                alpha: theme.brightness == Brightness.dark ? .80 : .88,
              ),
            ),
          ],
          widget.child,
        ],
      ),
    );
  }
}
