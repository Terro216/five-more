import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/background_frame.dart';

/// Shared by the editor, thumbnail and real ringing screen.
Rect backgroundRect(Size image, Size viewport, BackgroundFrame frame) {
  final oriented = frame.turns.isOdd ? Size(image.height, image.width) : image;
  final scale =
      math.max(
        viewport.width / oriented.width,
        viewport.height / oriented.height,
      ) *
      frame.zoom;
  final width = oriented.width * scale, height = oriented.height * scale;
  return Rect.fromLTWH(
    -(width - viewport.width) * frame.x,
    -(height - viewport.height) * frame.y,
    width,
    height,
  );
}

BackgroundFrame positionBackground(
  BackgroundFrame frame,
  Size image,
  Size viewport,
  Offset topLeft,
) {
  final size = backgroundRect(image, viewport, frame).size;
  double position(double offset, double overflow) =>
      overflow <= .0001 ? .5 : (-offset / overflow).clamp(0, 1);
  return frame.copyWith(
    x: position(topLeft.dx, size.width - viewport.width),
    y: position(topLeft.dy, size.height - viewport.height),
  );
}

class FramedPhoto extends StatelessWidget {
  const FramedPhoto({super.key, required this.image, required this.frame});
  final ui.Image image;
  final BackgroundFrame frame;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final rect = backgroundRect(
        Size(image.width.toDouble(), image.height.toDouble()),
        constraints.biggest,
        frame,
      );
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: RotatedBox(
                quarterTurns: frame.turns,
                child: RawImage(
                  image: image,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
