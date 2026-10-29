import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/sleep_entry.dart';
import '../../services/sleep_journal.dart';
import '../../services/local_database.dart';
import '../../services/sync_service.dart';

class MorningStats {
  MorningStats(List<AlarmEvent> source, {DateTime? from, DateTime? until}) {
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
      if (end != null &&
          (from == null || !end.at.isBefore(from)) &&
          (until == null || end.at.isBefore(until))) {
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
    this.archive = false,
  });
  final List<AlarmEvent> events;
  final SleepJournal journal;
  final DateTime now;
  final bool archive;
  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  int _days = 30, _limit = 50, _requestId = 0;
  DateTimeRange? _range;
  List<AlarmEvent>? _local;
  final List<AlarmEvent> _remote = [];
  Map<String, dynamic>? _summary;
  bool _loading = false, _olderLoading = false, _more = false, _cached = false;
  int? _beforeAt;
  String? _beforeId, _error;

  DateTime get _from =>
      _range?.start ??
      (_days == 0
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime(
              widget.now.year,
              widget.now.month,
              widget.now.day - _days + 1,
            ));
  DateTime get _until => _range == null
      ? DateTime(widget.now.year, widget.now.month, widget.now.day + 1)
      : DateTime(_range!.end.year, _range!.end.month, _range!.end.day + 1);
  bool get _cloud =>
      widget.archive &&
      SyncService.instance.enabled &&
      SyncService.instance.signedIn;
  String get _periodKey =>
      '${_from.millisecondsSinceEpoch}:${_until.millisecondsSinceEpoch}';
  @override
  void initState() {
    super.initState();
    if (widget.archive) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final request = ++_requestId;
    final from = _from, until = _until, key = _periodKey;
    setState(() {
      _loading = true;
      _error = null;
      _summary = null;
      _cached = false;
      _remote.clear();
      _more = false;
      _beforeAt = null;
      _beforeId = null;
      _local = null;
      _limit = 50;
    });
    try {
      if (usesSqlite) {
        final rows = await LocalDatabase.instance.records(
          'event',
          from: from.subtract(const Duration(days: 1)),
          until: until,
        );
        if (!mounted || request != _requestId) return;
        setState(() => _local = rows.map(AlarmEvent.fromJson).toList());
      }
      if (_cloud) {
        final cache = await LocalDatabase.instance.setting('history_summary');
        if (!mounted || request != _requestId) return;
        if (cache?['period'] == key) {
          setState(() {
            _summary = Map<String, dynamic>.from(cache!['summary'] as Map);
            _cached = true;
          });
        }
        final summary = await SyncService.instance.summary(from, until);
        if (!mounted || request != _requestId) return;
        setState(() {
          _summary = summary;
          _cached = false;
        });
        await LocalDatabase.instance.setSetting('history_summary', {
          'period': key,
          'summary': summary,
        });
        if (!mounted || request != _requestId) return;
        await _loadPage(request, from, until);
      }
    } catch (_) {
      if (mounted && request == _requestId) {
        setState(
          () => _error =
              'Не удалось обновить историю. Сохранённые данные доступны.',
        );
      }
    } finally {
      if (mounted && request == _requestId) setState(() => _loading = false);
    }
  }

  Future<void> _loadPage(int request, DateTime from, DateTime until) async {
    final page = await SyncService.instance.history(
      from,
      until,
      beforeAt: _beforeAt,
      beforeId: _beforeId,
    );
    if (!mounted || request != _requestId) return;
    final records = (page['records'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    // Cache downloaded pages without marking them as new local events.
    for (final row in records) {
      await LocalDatabase.instance.receive(row);
    }
    if (!mounted || request != _requestId) return;
    setState(() {
      _remote.addAll(
        records.map(
          (r) =>
              AlarmEvent.fromJson(Map<String, dynamic>.from(r['data'] as Map)),
        ),
      );
      _more = page['more'] == true;
      if (records.isNotEmpty) {
        _beforeAt = records.last['at'] as int;
        _beforeId = records.last['id'] as String;
      }
    });
  }

  Future<void> _older() async {
    if (_olderLoading) return;
    setState(() => _olderLoading = true);
    final request = _requestId;
    try {
      if (_more && _remote.length <= _limit + 50) {
        await _loadPage(request, _from, _until);
      }
      if (mounted && request == _requestId) setState(() => _limit += 50);
    } catch (_) {
      if (mounted && request == _requestId) {
        setState(
          () =>
              _error = 'Старые события пока не загрузились. Попробуй ещё раз.',
        );
      }
    } finally {
      if (mounted) setState(() => _olderLoading = false);
    }
  }

  void _select(int days) {
    setState(() {
      _days = days;
      _range = null;
      _limit = 50;
    });
    if (widget.archive) unawaited(_refresh());
  }

  List<({String label, double value})> _daily(
    List<dynamic> rows,
    String field,
  ) => rows.map((raw) {
    final row = raw as Map;
    final day = DateTime.parse(row['day'] as String);
    return (
      label: '${day.day}.${day.month}',
      value: (row[field] as num).toDouble(),
    );
  }).toList();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.journal,
    builder: (context, _) {
      final cutoff = _from, until = _until;
      final all = <String, AlarmEvent>{
        for (final e in [...?_local, ...widget.events, ..._remote])
          e.eventId: e,
      }.values.where((e) => !e.alarmId.startsWith('preview:')).toList();
      final events =
          all
              .where((e) => !e.at.isBefore(cutoff) && e.at.isBefore(until))
              .toList()
            ..sort((a, b) => b.at.compareTo(a.at));
      final stats = MorningStats(all, from: cutoff, until: until);
      final sleep =
          widget.journal.entries
              .where(
                (e) => !e.wokeAt.isBefore(cutoff) && e.wokeAt.isBefore(until),
              )
              .toList()
            ..sort((a, b) => a.wokeAt.compareTo(b.wokeAt));
      final insight = SleepInsight.fromEntries(sleep);
      final summary = _summary;
      final snoozes =
          summary?['snoozes'] as int? ??
          events.where((e) => e.type == 'snoozed').length;
      final outcomes = summary == null
          ? stats.outcomes
          : (summary['outcomes'] as List).cast<int>();
      final snoozeDays = <DateTime, double>{};
      if (summary == null) {
        for (final event in events.where((e) => e.type == 'snoozed')) {
          final day = DateTime(event.at.year, event.at.month, event.at.day);
          snoozeDays[day] = (snoozeDays[day] ?? 0) + 1;
        }
      } else {
        for (final raw in summary['snoozeDays'] as List) {
          snoozeDays[DateTime.parse(raw['day'] as String)] =
              (raw['value'] as num).toDouble();
        }
      }
      final first = _days == 0 && _range == null
          ? (snoozeDays.keys.toList()..sort()).firstOrNull ??
                until.subtract(const Duration(days: 1))
          : cutoff;
      final span = max(1, until.difference(first).inDays);
      final bucketDays = max(1, (span / 14).ceil());
      final buckets = <DateTime, double>{
        for (var i = 0; i < span; i += bucketDays)
          DateTime(first.year, first.month, first.day + i): 0,
      };
      for (final row in snoozeDays.entries) {
        final index = row.key.difference(first).inDays ~/ bucketDays;
        final day = DateTime(
          first.year,
          first.month,
          first.day + index * bucketDays,
        );
        if (buckets.containsKey(day)) buckets[day] = buckets[day]! + row.value;
      }
      final wakePoints = summary == null
          ? stats.wakeMinutes
                .map(
                  (p) => (label: '${p.at.day}.${p.at.month}', value: p.value),
                )
                .toList()
          : _daily(summary['wakeDays'] as List, 'value');
      final sleepPoints = summary == null
          ? sleep
                .map(
                  (e) => (
                    label: '${e.wokeAt.day}.${e.wokeAt.month}',
                    value: e.hours,
                  ),
                )
                .toList()
          : _daily(summary['sleepDays'] as List, 'hours');
      final ratingPoints = summary == null
          ? sleep
                .map(
                  (e) => (
                    label: '${e.wokeAt.day}.${e.wokeAt.month}',
                    value: (e.sleepQuality + e.wakeQuality) / 2,
                  ),
                )
                .toList()
          : _daily(
              (summary['sleepDays'] as List)
                  .map(
                    (r) => {
                      ...r as Map,
                      'rating':
                          ((r['sleepQuality'] as num) +
                              (r['wakeQuality'] as num)) /
                          2,
                    },
                  )
                  .toList(),
              'rating',
            );
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Как прошло утро',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.archive)
                IconButton(
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Обновить историю',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...[7, 30, 90, 0].map(
                (days) => ChoiceChip(
                  label: Text(days == 0 ? 'Всё время' : '$days дней'),
                  selected: _range == null && _days == days,
                  onSelected: (_) => _select(days),
                ),
              ),
              ActionChip(
                label: Text(
                  _range == null
                      ? 'Период…'
                      : '${_range!.start.day}.${_range!.start.month}.${_range!.start.year} — ${_range!.end.day}.${_range!.end.month}.${_range!.end.year}',
                ),
                onPressed: () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: widget.now,
                    initialDateRange: _range,
                  );
                  if (range != null && mounted) {
                    setState(() {
                      _range = range;
                      _limit = 50;
                    });
                    if (widget.archive) unawaited(_refresh());
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Text(
            summary == null
                ? 'История, сохранённая на этом телефоне'
                : _cached
                ? 'Сохранённый расчёт с сервера · обновление недоступно'
                : 'Графики по всем синхронизированным данным периода',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 24),
          if (events.isEmpty && outcomes.every((n) => n == 0) && snoozes == 0)
            const Text(
              'Пока нет утренних событий.',
              style: TextStyle(color: muted),
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
                'Один столбик — $bucketDays ${_dayWord(bucketDays)}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            const SizedBox(height: 24),
            _heading('Чем закончился звонок', 'По отдельным подъёмам'),
            _outcomes(outcomes),
            const SizedBox(height: 24),
            _heading(
              'От звонка до отключения',
              summary == null
                  ? 'Минуты · только завершённые задания'
                  : 'Среднее за день · только завершённые задания',
            ),
            if (wakePoints.isEmpty)
              const Text(
                'Пока нет пары «звонок — задание пройдено».',
                style: TextStyle(color: muted),
              )
            else
              DataPlot(
                points: wakePoints,
                unit: 'мин',
                color: const Color(0xFF8EDDAB),
              ),
          ],
          const SizedBox(height: 28),
          _heading('Сон и самочувствие', 'Расчётное время сна и твои оценки'),
          if (sleepPoints.isEmpty)
            const Text('Пока нет оценок сна.', style: TextStyle(color: muted))
          else ...[
            DataPlot(
              points: sleepPoints,
              unit: 'ч · расчётный сон',
              color: const Color(0xFF7FBFFF),
            ),
            const SizedBox(height: 16),
            DataPlot(
              points: ratingPoints,
              unit: 'средняя оценка из 5',
              color: morning,
              ceiling: 5,
            ),
          ],
          if (insight != null) ...[
            const SizedBox(height: 12),
            Text(
              'Лучшие оценки за период — после примерно ${insight.hours.toStringAsFixed(1)} ч: ${insight.rating.toStringAsFixed(1)} из 5, наблюдений: ${insight.samples}. Это наблюдение по твоим ответам.',
              style: const TextStyle(color: muted, height: 1.5),
            ),
          ],
          const SizedBox(height: 28),
          _heading('События', '${events.length} загружено за период'),
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
          if (events.length > _limit || _more)
            TextButton(
              onPressed: _olderLoading ? null : _older,
              child: Text(_olderLoading ? 'Загружаю…' : 'Показать ещё 50'),
            ),
          const SizedBox(height: 16),
          const Text(
            'Тренировки в историю не попадают.',
            style: TextStyle(color: muted, fontSize: 12),
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

String _dayWord(int count) {
  final lastTwo = count.abs() % 100;
  if (lastTwo >= 11 && lastTwo <= 14) return 'дней';
  return switch (lastTwo % 10) {
    1 => 'день',
    2 || 3 || 4 => 'дня',
    _ => 'дней',
  };
}
