import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/sleep_entry.dart';
import '../../services/sleep_journal.dart';

class MorningStats {
  MorningStats(List<AlarmEvent> source) {
    final groups = <String, List<AlarmEvent>>{};
    for (final e in source) {
      if (e.alarmId.startsWith('preview:') || e.occurrenceId.isEmpty) continue;
      groups.putIfAbsent('${e.alarmId}:${e.occurrenceId}', () => []).add(e);
    }
    for (final group in groups.values) {
      group.sort((a, b) => a.at.compareTo(b.at));
      final start = group
          .where((e) => e.type == 'fired' || e.type == 'ringing')
          .firstOrNull;
      final end = group
          .where(
            (e) => const [
              'dismissed',
              'emergency',
              'emergency_dismissed',
              'timed_out',
              'missed',
            ].contains(e.type),
          )
          .lastOrNull;
      if (end != null) {
        final category = end.type == 'dismissed'
            ? 0
            : const ['emergency', 'emergency_dismissed'].contains(end.type)
            ? 1
            : 2;
        outcomes[category]++;
        if (start != null && category == 0 && !end.at.isBefore(start.at)) {
          wakeMinutes.add((
            at: end.at,
            value: end.at.difference(start.at).inSeconds / 60,
          ));
        }
      }
    }
    wakeMinutes.sort((a, b) => a.at.compareTo(b.at));
  }
  final outcomes = [0, 0, 0];
  final wakeMinutes = <({DateTime at, double value})>[];
}

class HistoryView extends StatefulWidget {
  const HistoryView({
    super.key,
    required this.events,
    required this.journal,
    required this.now,
  });
  final List<AlarmEvent> events;
  final SleepJournal journal;
  final DateTime now;
  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  int _days = 30, _limit = 50;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.journal,
    builder: (context, _) {
      final cutoff = _days == 0
          ? DateTime(1970)
          : DateTime(
              widget.now.year,
              widget.now.month,
              widget.now.day - _days + 1,
            );
      final events = widget.events
          .where(
            (e) => !e.at.isBefore(cutoff) && !e.alarmId.startsWith('preview:'),
          )
          .toList();
      final stats = MorningStats(events);
      final sleep =
          widget.journal.entries
              .where((e) => !e.wokeAt.isBefore(cutoff))
              .toList()
            ..sort((a, b) => a.wokeAt.compareTo(b.wokeAt));
      final insight = SleepInsight.fromEntries(widget.journal.entries);
      final snoozes = events.where((e) => e.type == 'snoozed').length;
      final buckets = <DateTime, double>{};
      final start = _days == 0 && events.isNotEmpty
          ? events.map((e) => e.at).reduce((a, b) => a.isBefore(b) ? a : b)
          : cutoff;
      final span = max(
        1,
        DateTime(
              widget.now.year,
              widget.now.month,
              widget.now.day,
            ).difference(DateTime(start.year, start.month, start.day)).inDays +
            1,
      );
      final bucketDays = max(1, (span / 14).ceil());
      for (var i = 0; i < span; i += bucketDays) {
        buckets[DateTime(start.year, start.month, start.day + i)] = 0;
      }
      for (final event in events.where((e) => e.type == 'snoozed')) {
        final index =
            DateTime(
              event.at.year,
              event.at.month,
              event.at.day,
            ).difference(DateTime(start.year, start.month, start.day)).inDays ~/
            bucketDays;
        final key = DateTime(
          start.year,
          start.month,
          start.day + index * bucketDays,
        );
        if (buckets.containsKey(key)) buckets[key] = buckets[key]! + 1;
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
        children: [
          const Text(
            'Как прошло утро',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [7, 30, 90, 0]
                .map(
                  (days) => ChoiceChip(
                    label: Text(days == 0 ? 'Всё время' : '$days дней'),
                    selected: _days == days,
                    onSelected: (_) => setState(() {
                      _days = days;
                      _limit = 50;
                    }),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 24),
          if (events.isEmpty)
            const Text(
              'Первое утро ещё впереди. Здесь появятся графики переносов и подъёмов. Тренировки в статистику не входят.',
              style: TextStyle(color: muted, height: 1.5),
            )
          else ...[
            _heading('Переносы', '$snoozes за выбранный период'),
            DataPlot(
              points: buckets.entries
                  .map(
                    (e) =>
                        (label: '${e.key.day}.${e.key.month}', value: e.value),
                  )
                  .toList(),
              unit: 'переносов',
              bars: true,
              color: morning,
            ),
            if (bucketDays > 1)
              Text(
                'Один столбик — $bucketDays дней',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            const SizedBox(height: 24),
            _heading('Чем закончился звонок', 'По отдельным подъёмам'),
            _outcomes(stats.outcomes),
            const SizedBox(height: 24),
            _heading(
              'От звонка до отключения',
              'Минуты · только завершённые задания',
            ),
            if (stats.wakeMinutes.isEmpty)
              const Text(
                'Пока нет пары «звонок — задание пройдено».',
                style: TextStyle(color: muted),
              )
            else
              DataPlot(
                points: stats.wakeMinutes
                    .map(
                      (p) =>
                          (label: '${p.at.day}.${p.at.month}', value: p.value),
                    )
                    .toList(),
                unit: 'мин',
                color: const Color(0xFF8EDDAB),
              ),
          ],
          const SizedBox(height: 28),
          _heading('Сон и самочувствие', 'Твои утренние оценки'),
          if (sleep.isEmpty)
            const Text(
              'После подъёма оцени сон и пробуждение на главной. Здесь появятся продолжительность и оценки.',
              style: TextStyle(color: muted, height: 1.5),
            )
          else ...[
            DataPlot(
              points: sleep
                  .map(
                    (e) => (
                      label: '${e.wokeAt.day}.${e.wokeAt.month}',
                      value: e.hours,
                    ),
                  )
                  .toList(),
              unit: 'ч в постели',
              color: const Color(0xFF7FBFFF),
            ),
            const SizedBox(height: 16),
            DataPlot(
              points: sleep
                  .map(
                    (e) => (
                      label: '${e.wokeAt.day}.${e.wokeAt.month}',
                      value: (e.sleepQuality + e.wakeQuality) / 2,
                    ),
                  )
                  .toList(),
              unit: 'средняя оценка из 5',
              color: morning,
              ceiling: 5,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            insight == null
                ? 'Для личного ориентира нужны хотя бы 7 оценок и два диапазона длительности с 3 ночами в каждом.'
                : 'Пока лучшие оценки — после примерно ${insight.hours.toStringAsFixed(1)} ч в постели: ${insight.rating.toStringAsFixed(1)} из 5, Наблюдений: ${insight.samples}. Это наблюдение по твоим ответам, а не рассчитанная норма сна.',
            style: const TextStyle(color: muted, height: 1.5),
          ),
          const SizedBox(height: 28),
          _heading(
            'События',
            '${events.length} за период · всего ${widget.events.length}',
          ),
          ...events
              .take(_limit)
              .map(
                (event) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    event.type == 'snoozed'
                        ? Icons.snooze_rounded
                        : event.type == 'dismissed'
                        ? Icons.check_rounded
                        : Icons.alarm_rounded,
                    color: muted,
                  ),
                  title: Text(event.label),
                  subtitle: Text(
                    '${event.at.day}.${event.at.month}.${event.at.year}',
                  ),
                  trailing: Text(
                    '${event.at.hour.toString().padLeft(2, '0')}:${event.at.minute.toString().padLeft(2, '0')}',
                  ),
                ),
              ),
          if (events.length > _limit)
            TextButton(
              onPressed: () => setState(() => _limit += 50),
              child: const Text('Показать ещё 50'),
            ),
          const SizedBox(height: 16),
          const Text(
            'Вся история остаётся на этом устройстве. Тренировки в неё не попадают.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.5),
          ),
        ],
      );
    },
  );
  Widget _heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        Text(subtitle, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    ),
  );
  Widget _outcomes(List<int> values) {
    const names = ['С заданием', 'Аварийно', 'Пропуск / тайм-аут'];
    const colors = [Color(0xFF8EDDAB), Color(0xFFF3C96B), Color(0xFFFFB4AB)];
    final total = values.fold(0, (sum, n) => sum + n);
    return Column(
      children: [
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: List.generate(
                3,
                (i) => values[i] == 0
                    ? const SizedBox.shrink()
                    : Expanded(
                        flex: values[i],
                        child: Container(height: 20, color: colors[i]),
                      ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: List.generate(
            3,
            (i) => Text(
              '${names[i]} · ${values[i]}',
              style: TextStyle(color: colors[i], fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class DataPlot extends StatefulWidget {
  const DataPlot({
    super.key,
    required this.points,
    required this.unit,
    required this.color,
    this.bars = false,
    this.ceiling,
  });
  final List<({String label, double value})> points;
  final String unit;
  final Color color;
  final bool bars;
  final double? ceiling;
  @override
  State<DataPlot> createState() => _DataPlotState();
}

class _DataPlotState extends State<DataPlot> {
  int? _selected;
  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.isEmpty) return const SizedBox.shrink();
    final index = (_selected ?? points.length - 1).clamp(0, points.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${points[index].label} · ${points[index].value.toStringAsFixed(widget.bars ? 0 : 1)} ${widget.unit}',
          style: TextStyle(color: widget.color),
        ),
        const SizedBox(height: 8),
        Semantics(
          label:
              '${widget.unit}. ${points.map((p) => '${p.label}: ${p.value.toStringAsFixed(1)}').join(', ')}',
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              onTapDown: (e) => setState(
                () => _selected =
                    ((e.localPosition.dx - 28) /
                            max(1, constraints.maxWidth - 40) *
                            points.length)
                        .floor()
                        .clamp(0, points.length - 1),
              ),
              child: CustomPaint(
                size: Size(constraints.maxWidth, 140),
                painter: _PlotPainter(
                  points,
                  widget.color,
                  widget.bars,
                  widget.ceiling,
                  index,
                ),
              ),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              points.first.label,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
            Text(
              points.last.label,
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlotPainter extends CustomPainter {
  _PlotPainter(this.points, this.color, this.bars, this.ceiling, this.selected);
  final List<({String label, double value})> points;
  final Color color;
  final bool bars;
  final double? ceiling;
  final int selected;
  @override
  void paint(Canvas canvas, Size size) {
    final high = ceiling ?? max(1.0, points.map((p) => p.value).reduce(max));
    const left = 28.0;
    final width = size.width - left - 12;
    final height = size.height - 16;
    for (var i = 0; i < 3; i++) {
      final y = 8 + height * i / 2;
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width, y),
        Paint()..color = muted.withValues(alpha: .18),
      );
      final text = TextPainter(
        text: TextSpan(
          text: (high * (1 - i / 2)).toStringAsFixed(0),
          style: const TextStyle(
            color: muted,
            fontSize: 10,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(0, y - 6));
      text.dispose();
    }
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = left + width * (i + .5) / points.length;
      final y = 8 + height * (1 - (points[i].value / high).clamp(0, 1));
      if (bars) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              x - width / points.length * .3,
              y,
              x + width / points.length * .3,
              8 + height,
            ),
            const Radius.circular(3),
          ),
          Paint()..color = color.withValues(alpha: i == selected ? 1 : .55),
        );
      } else {
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(
          Offset(x, y),
          i == selected ? 5 : 2.5,
          Paint()..color = color,
        );
      }
    }
    if (!bars) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_PlotPainter old) => true;
}
