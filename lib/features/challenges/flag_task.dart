import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'challenge_models.dart';

class CountryFlag {
  const CountryFlag(
    this.country,
    this.colors, {
    this.vertical = false,
    this.disc,
  });
  final String country;
  final List<int> colors;
  final bool vertical;
  final int? disc;
}

const countryFlags = [
  CountryFlag('Франция', [0xFF002654, 0xFFFFFFFF, 0xFFED2939], vertical: true),
  CountryFlag('Италия', [0xFF009246, 0xFFFFFFFF, 0xFFCE2B37], vertical: true),
  CountryFlag('Германия', [0xFF000000, 0xFFDD0000, 0xFFFFCC00]),
  CountryFlag('Нидерланды', [0xFFAE1C28, 0xFFFFFFFF, 0xFF21468B]),
  CountryFlag('Россия', [0xFFFFFFFF, 0xFF0039A6, 0xFFD52B1E]),
  CountryFlag('Украина', [0xFF0057B7, 0xFFFFD700]),
  CountryFlag('Польша', [0xFFFFFFFF, 0xFFDC143C]),
  CountryFlag('Индонезия', [0xFFFF0000, 0xFFFFFFFF]),
  CountryFlag('Япония', [0xFFFFFFFF], disc: 0xFFBC002D),
  CountryFlag('Бангладеш', [0xFF006A4E], disc: 0xFFF42A41),
  CountryFlag('Бельгия', [0xFF000000, 0xFFFAE042, 0xFFED2939], vertical: true),
  CountryFlag('Ирландия', [0xFF169B62, 0xFFFFFFFF, 0xFFFF883E], vertical: true),
  CountryFlag('Кот-д’Ивуар', [
    0xFFF77F00,
    0xFFFFFFFF,
    0xFF009E60,
  ], vertical: true),
  CountryFlag('Румыния', [0xFF002B7F, 0xFFFCD116, 0xFFCE1126], vertical: true),
  CountryFlag('Венгрия', [0xFFCE2939, 0xFFFFFFFF, 0xFF477050]),
  CountryFlag('Болгария', [0xFFFFFFFF, 0xFF00966E, 0xFFD62612]),
  CountryFlag('Австрия', [0xFFED2939, 0xFFFFFFFF, 0xFFED2939]),
  CountryFlag('Литва', [0xFFFDB913, 0xFF006A44, 0xFFC1272D]),
  CountryFlag('Эстония', [0xFF4891D9, 0xFF000000, 0xFFFFFFFF]),
  CountryFlag('Люксембург', [0xFFED2939, 0xFFFFFFFF, 0xFF00A1DE]),
  CountryFlag('Нигерия', [0xFF008751, 0xFFFFFFFF, 0xFF008751], vertical: true),
  CountryFlag('Гвинея', [0xFFCE1126, 0xFFFCD116, 0xFF009460], vertical: true),
  CountryFlag('Мали', [0xFF14B53A, 0xFFFCD116, 0xFFCE1126], vertical: true),
  CountryFlag('Йемен', [0xFFCE1126, 0xFFFFFFFF, 0xFF000000]),
];

class FlagTask extends StatefulWidget {
  const FlagTask({super.key, required this.difficulty, required this.onAnswer});
  final ChallengeDifficulty difficulty;
  final ValueChanged<bool> onAnswer;
  @override
  State<FlagTask> createState() => _FlagTaskState();
}

class _FlagTaskState extends State<FlagTask> {
  final _random = Random();
  late final CountryFlag _flag;
  late final List<CountryFlag> _choices;
  final _input = TextEditingController();
  @override
  void initState() {
    super.initState();
    final pool =
        countryFlags
            .take(widget.difficulty.index < 2 ? 10 : countryFlags.length)
            .toList()
          ..shuffle(_random);
    _flag = pool.first;
    _choices = pool.take(widget.difficulty.index < 2 ? 4 : 6).toList()
      ..shuffle(_random);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool _accepts(String text) =>
      text
          .trim()
          .toLowerCase()
          .replaceAll('ё', 'е')
          .replaceAll(RegExp('[’\x27 -]'), '') ==
      _flag.country
          .toLowerCase()
          .replaceAll('ё', 'е')
          .replaceAll(RegExp('[’\x27 -]'), '');
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Чей это флаг?',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22),
      ),
      const SizedBox(height: 20),
      Semantics(
        label:
            'Флаг: ${_flag.vertical ? 'вертикальные' : 'горизонтальные'} полосы. Визуальное задание.',
        child: AspectRatio(
          aspectRatio: 1.5,
          child: CustomPaint(painter: _FlagPainter(_flag)),
        ),
      ),
      const SizedBox(height: 24),
      if (widget.difficulty == ChallengeDifficulty.extreme) ...[
        TextField(
          controller: _input,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Название страны'),
          onSubmitted: (text) => widget.onAnswer(_accepts(text)),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onAnswer(_accepts(_input.text)),
          child: const Text('Проверить'),
        ),
      ] else
        ..._choices.map(
          (choice) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              onPressed: () => widget.onAnswer(choice == _flag),
              child: Text(choice.country),
            ),
          ),
        ),
    ],
  );
}

class _FlagPainter extends CustomPainter {
  _FlagPainter(this.flag);
  final CountryFlag flag;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < flag.colors.length; i++) {
      final count = flag.colors.length;
      canvas.drawRect(
        flag.vertical
            ? Rect.fromLTWH(
                i * size.width / count,
                0,
                size.width / count,
                size.height,
              )
            : Rect.fromLTWH(
                0,
                i * size.height / count,
                size.width,
                size.height / count,
              ),
        Paint()..color = Color(flag.colors[i]),
      );
    }
    if (flag.disc != null) {
      canvas.drawCircle(
        Offset(
          size.width * (flag.country == 'Бангладеш' ? .45 : .5),
          size.height / 2,
        ),
        size.height * .3,
        Paint()..color = Color(flag.disc!),
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = muted
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FlagPainter old) => old.flag != flag;
}
