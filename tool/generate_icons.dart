// Run with: flutter test tool/generate_icons.dart
// Flutter's own vector renderer generates the launcher assets; no image service
// or third-party rasterizer is needed.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

Future<void> writeIcon(String file, int size) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)..scale(size / 1024);
  canvas.drawPaint(Paint()..color = const Color(0xFF141916));
  final paint = Paint()
    ..color = const Color(0xFFFFD38A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 48
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas.drawCircle(const Offset(512, 545), 285, paint);
  canvas.drawLine(const Offset(286, 244), const Offset(349, 198), paint);
  canvas.drawLine(const Offset(674, 198), const Offset(737, 244), paint);
  canvas.drawLine(const Offset(336, 787), const Offset(309, 831), paint);
  canvas.drawLine(const Offset(688, 787), const Offset(715, 831), paint);
  final five = Path()
    ..moveTo(600, 397)
    ..lineTo(440, 397)
    ..lineTo(422, 530)
    ..cubicTo(482, 510, 604, 498, 606, 608)
    ..cubicTo(608, 707, 478, 738, 420, 665);
  canvas.drawPath(five, paint..strokeWidth = 52);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final bytes = await image.toByteData(format: ImageByteFormat.png);
  final output = File(file);
  output.parent.createSync(recursive: true);
  await output.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

void main() {
  test('render original Five More launcher artwork', () async {
    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      await writeIcon(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        entry.value,
      );
    }
    const iconSet = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final manifest =
        jsonDecode(File('$iconSet/Contents.json').readAsStringSync()) as Map;
    for (final entry in manifest['images'] as List) {
      final dimensions = double.parse(
        (entry['size'] as String).split('x').first,
      );
      final scale = double.parse(
        (entry['scale'] as String).replaceAll('x', ''),
      );
      await writeIcon(
        '$iconSet/${entry['filename']}',
        (dimensions * scale).round(),
      );
    }
    for (final size in [192, 512]) {
      await writeIcon('web/icons/Icon-$size.png', size);
      await writeIcon('web/icons/Icon-maskable-$size.png', size);
    }
    await writeIcon('web/favicon.png', 64);
  });
}
