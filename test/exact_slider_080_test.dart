import 'package:five_more/widgets/exact_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'invalid exact edits remain visible and nap can exceed slider range',
    (tester) async {
      var saved = 20;
      var valid = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ExactSlider(
                label: 'Вздремнуть',
                unit: 'мин',
                value: saved,
                min: 1,
                max: 1440,
                sliderMax: 180,
                onValidityChanged: (v) => valid = v,
                onChanged: (v) => setState(() => saved = v),
              ),
            ),
          ),
        ),
      );
      for (final text in ['', '1.5', '-1', '1441']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        expect(valid, isFalse);
        expect(saved, 20);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          text,
        );
        expect(find.text('Целое число от 1 до 1440'), findsOneWidget);
      }
      await tester.enterText(find.byType(TextField), '1440');
      await tester.pump();
      expect(valid, isTrue);
      expect(saved, 1440);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 180);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
      await tester.pump();
      expect(saved, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '1',
      );
    },
  );
}
