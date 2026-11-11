import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/alarm.dart';
import '../services/native_extras.dart';

/// A missing/locked photo must never obstruct the alarm's controls or sound.
class AlarmBackground extends StatefulWidget {
  const AlarmBackground({super.key, required this.name, required this.child});
  final String name;
  final Widget child;
  @override
  State<AlarmBackground> createState() => _AlarmBackgroundState();
}

class _AlarmBackgroundState extends State<AlarmBackground> {
  late Future<Uint8List?> _image = _read();
  Future<Uint8List?> _read() async {
    if (!validBackgroundName(widget.name)) return null;
    try {
      return await NativeExtras.call<Uint8List>('readBackground', {
        'file': widget.name,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(AlarmBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) _image = _read();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: FutureBuilder<Uint8List?>(
        future: _image,
        builder: (context, snapshot) => Stack(
          fit: StackFit.expand,
          children: [
            if (snapshot.data != null) ...[
              Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              ColoredBox(
                color: theme.scaffoldBackgroundColor.withValues(
                  alpha: theme.brightness == Brightness.dark ? .80 : .88,
                ),
              ),
            ],
            widget.child,
          ],
        ),
      ),
    );
  }
}
