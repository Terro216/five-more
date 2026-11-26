import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../l10n/strings.dart';
import 'challenge_models.dart';

enum FlagCountry {
  france,
  italy,
  germany,
  netherlands,
  russia,
  ukraine,
  poland,
  indonesia,
  japan,
  bangladesh,
  belgium,
  ireland,
  ivoryCoast,
  romania,
  hungary,
  bulgaria,
  austria,
  lithuania,
  estonia,
  luxembourg,
  nigeria,
  guinea,
  mali,
  yemen,
}

class CountryFlag {
  const CountryFlag(this.id, this.colors, {this.vertical = false, this.disc});
  final FlagCountry id;
  String get country => switch (id) {
    FlagCountry.france => appStrings.countryFrance,
    FlagCountry.italy => appStrings.countryItaly,
    FlagCountry.germany => appStrings.countryGermany,
    FlagCountry.netherlands => appStrings.countryNetherlands,
    FlagCountry.russia => appStrings.countryRussia,
    FlagCountry.ukraine => appStrings.countryUkraine,
    FlagCountry.poland => appStrings.countryPoland,
    FlagCountry.indonesia => appStrings.countryIndonesia,
    FlagCountry.japan => appStrings.countryJapan,
    FlagCountry.bangladesh => appStrings.countryBangladesh,
    FlagCountry.belgium => appStrings.countryBelgium,
    FlagCountry.ireland => appStrings.countryIreland,
    FlagCountry.ivoryCoast => appStrings.countryIvoryCoast,
    FlagCountry.romania => appStrings.countryRomania,
    FlagCountry.hungary => appStrings.countryHungary,
    FlagCountry.bulgaria => appStrings.countryBulgaria,
    FlagCountry.austria => appStrings.countryAustria,
    FlagCountry.lithuania => appStrings.countryLithuania,
    FlagCountry.estonia => appStrings.countryEstonia,
    FlagCountry.luxembourg => appStrings.countryLuxembourg,
    FlagCountry.nigeria => appStrings.countryNigeria,
    FlagCountry.guinea => appStrings.countryGuinea,
    FlagCountry.mali => appStrings.countryMali,
    FlagCountry.yemen => appStrings.countryYemen,
  };
  final List<int> colors;
  final bool vertical;
  final int? disc;
}

const countryFlags = [
  CountryFlag(FlagCountry.france, [
    0xFF002654,
    0xFFFFFFFF,
    0xFFED2939,
  ], vertical: true),
  CountryFlag(FlagCountry.italy, [
    0xFF009246,
    0xFFFFFFFF,
    0xFFCE2B37,
  ], vertical: true),
  CountryFlag(FlagCountry.germany, [0xFF000000, 0xFFDD0000, 0xFFFFCC00]),
  CountryFlag(FlagCountry.netherlands, [0xFFAE1C28, 0xFFFFFFFF, 0xFF21468B]),
  CountryFlag(FlagCountry.russia, [0xFFFFFFFF, 0xFF0039A6, 0xFFD52B1E]),
  CountryFlag(FlagCountry.ukraine, [0xFF0057B7, 0xFFFFD700]),
  CountryFlag(FlagCountry.poland, [0xFFFFFFFF, 0xFFDC143C]),
  CountryFlag(FlagCountry.indonesia, [0xFFFF0000, 0xFFFFFFFF]),
  CountryFlag(FlagCountry.japan, [0xFFFFFFFF], disc: 0xFFBC002D),
  CountryFlag(FlagCountry.bangladesh, [0xFF006A4E], disc: 0xFFF42A41),
  CountryFlag(FlagCountry.belgium, [
    0xFF000000,
    0xFFFAE042,
    0xFFED2939,
  ], vertical: true),
  CountryFlag(FlagCountry.ireland, [
    0xFF169B62,
    0xFFFFFFFF,
    0xFFFF883E,
  ], vertical: true),
  CountryFlag(FlagCountry.ivoryCoast, [
    0xFFF77F00,
    0xFFFFFFFF,
    0xFF009E60,
  ], vertical: true),
  CountryFlag(FlagCountry.romania, [
    0xFF002B7F,
    0xFFFCD116,
    0xFFCE1126,
  ], vertical: true),
  CountryFlag(FlagCountry.hungary, [0xFFCE2939, 0xFFFFFFFF, 0xFF477050]),
  CountryFlag(FlagCountry.bulgaria, [0xFFFFFFFF, 0xFF00966E, 0xFFD62612]),
  CountryFlag(FlagCountry.austria, [0xFFED2939, 0xFFFFFFFF, 0xFFED2939]),
  CountryFlag(FlagCountry.lithuania, [0xFFFDB913, 0xFF006A44, 0xFFC1272D]),
  CountryFlag(FlagCountry.estonia, [0xFF4891D9, 0xFF000000, 0xFFFFFFFF]),
  CountryFlag(FlagCountry.luxembourg, [0xFFED2939, 0xFFFFFFFF, 0xFF00A1DE]),
  CountryFlag(FlagCountry.nigeria, [
    0xFF008751,
    0xFFFFFFFF,
    0xFF008751,
  ], vertical: true),
  CountryFlag(FlagCountry.guinea, [
    0xFFCE1126,
    0xFFFCD116,
    0xFF009460,
  ], vertical: true),
  CountryFlag(FlagCountry.mali, [
    0xFF14B53A,
    0xFFFCD116,
    0xFFCE1126,
  ], vertical: true),
  CountryFlag(FlagCountry.yemen, [0xFFCE1126, 0xFFFFFFFF, 0xFF000000]),
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

  String _countryKey(String text) => text
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll('ô', 'o')
      .replaceAll(RegExp("[’' -]"), '');

  bool _accepts(String answer) {
    final key = _countryKey(answer);
    return key == _countryKey(_flag.country) ||
        (_flag.id == FlagCountry.ivoryCoast && key == 'cotedivoire') ||
        (_flag.id == FlagCountry.netherlands && key == 'thenetherlands');
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        context.strings.flagQuestion,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22),
      ),
      const SizedBox(height: 20),
      Semantics(
        label: context.strings.flagDescription(
          _flag.vertical
              ? context.strings.vertical
              : context.strings.horizontal,
        ),
        child: AspectRatio(
          aspectRatio: 1.5,
          child: CustomPaint(
            painter: _FlagPainter(_flag, context.palette.muted),
          ),
        ),
      ),
      const SizedBox(height: 24),
      if (widget.difficulty == ChallengeDifficulty.extreme) ...[
        TextField(
          controller: _input,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: context.strings.countryName),
          onSubmitted: (text) => widget.onAnswer(_accepts(text)),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onAnswer(_accepts(_input.text)),
          child: Text(context.strings.check),
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
  _FlagPainter(this.flag, this.border);
  final Color border;
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
          size.width * (flag.id == FlagCountry.bangladesh ? .45 : .5),
          size.height / 2,
        ),
        size.height * .3,
        Paint()..color = Color(flag.disc!),
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FlagPainter old) =>
      old.flag != flag || old.border != border;
}
