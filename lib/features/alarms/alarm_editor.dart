import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../../models/wake_preset.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import '../challenges/physical_tasks.dart';
import '../../services/native_extras.dart';
import '../../widgets/time_composer.dart';

class AlarmEditor extends StatefulWidget {
  const AlarmEditor({super.key, required this.controller, this.alarm});
  final AlarmController controller;
  final Alarm? alarm;

  @override
  State<AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<AlarmEditor> {
  late Alarm _draft;
  late final TextEditingController _title;
  bool _saving = false;
  int _practiceSnoozes = 0;
  String? _error;
  final _advanced = ExpansibleController();
  bool _nap = false;
  int _napMinutes = 20;
  Timer? _clock;
  bool _soundBusy = false;
  bool _timeValid = true;

  @override
  void initState() {
    super.initState();
    _draft = widget.alarm ?? Alarm.fresh();
    _title = TextEditingController(text: _draft.title);
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _advanced.dispose();
    _clock?.cancel();
    if (NativeExtras.available) {
      unawaited(NativeExtras.call<void>('stopAudio').catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _save() async {
    if ((_draft.challengeKind == ChallengeKind.qr ||
            (_draft.challengeKind == ChallengeKind.mixed &&
                _draft.mixOrder.contains(ChallengeKind.qr))) &&
        _draft.qrValue.isEmpty) {
      setState(() => _error = 'Сначала зарегистрируй QR-код.');
      return;
    }
    if (_nap) {
      final at = widget.controller.now.add(Duration(minutes: _napMinutes));
      _draft = _draft.copyWith(
        hour: at.hour,
        minute: at.minute,
        weekdays: const [],
        oneShotAt: at,
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.controller.saveAlarm(
      _draft.copyWith(
        title: _title.text == _draft.title ? _draft.title : _title.text.trim(),
        enabled: widget.alarm?.enabled ?? true,
      ),
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = result.error;
      });
    }
  }

  void _practice() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChallengeScreen(
          kind: _draft.challengeKind,
          order: _draft.mixOrder,
          qrValue: _draft.qrValue,
          difficulty: _draft.difficultyForSnoozes(_practiceSnoozes),
          practice: true,
          onComplete: () => Navigator.of(context).pop(),
          onEmergencyExit: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.alarm == null ? 'Новый будильник' : 'Настроить подъём',
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('alarm-save-error'),
                    style: const TextStyle(
                      color: Color(0xFFFFB4AB),
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            FilledButton(
              key: const ValueKey('save-alarm'),
              onPressed: _saving || (!_nap && !_timeValid) ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      widget.controller.device.supported
                          ? 'Сохранить будильник'
                          : 'Сохранить черновик',
                      textAlign: TextAlign.center,
                    ),
            ),
          ],
        ),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          children: [
            if (!widget.controller.device.supported)
              const _Note(
                icon: Icons.info_outline_rounded,
                text: 'Режим знакомства: настройки сохранятся, но будильник не зазвонит.',
              ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Будильник')),
                ButtonSegment(value: true, label: Text('Вздремнуть')),
              ],
              selected: {_nap},
              onSelectionChanged: _saving
                  ? null
                  : (v) => setState(() {
                      _nap = v.single;
                      if (!_nap) _draft = _draft.copyWith(clearOneShotAt: true);
                    }),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _nap
                    ? 'Звонок в ${clockLabel(TimeOfDay.fromDateTime(widget.controller.now.add(Duration(minutes: _napMinutes))))} · через $_napMinutes мин'
                    : 'До звонка ${remainingLabel(_draft.nextOccurrence(widget.controller.now), widget.controller.now)}',
                key: const ValueKey('alarm-time-remaining'),
                style: const TextStyle(color: morning, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
            if (_nap) ...[
              Text(
                '$_napMinutes минут',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 36, color: morning),
              ),
              Slider(
                value: _napMinutes.toDouble(),
                min: 1,
                max: 180,
                divisions: 179,
                label: '$_napMinutes мин',
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _napMinutes = v.round()),
              ),
              Wrap(
                spacing: 8,
                children: [10, 20, 30, 60, 90]
                    .map(
                      (n) => ChoiceChip(
                        label: Text('$n мин'),
                        selected: _napMinutes == n,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _napMinutes = n),
                      ),
                    )
                    .toList(),
              ),
            ] else
              TimeComposer(
                time: TimeOfDay(hour: _draft.hour, minute: _draft.minute),
                enabled: !_saving,
                onValidityChanged: (valid) =>
                    setState(() => _timeValid = valid),
                onChanged: (time) => setState(
                  () => _draft = _draft.copyWith(
                    hour: time.hour,
                    minute: time.minute,
                    clearOneShotAt: true,
                  ),
                ),
              ),
            if (!_nap) ...[
              const _Heading('Когда повторять'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _preset('Один раз', const []),
                  _preset('Будни', const [1, 2, 3, 4, 5]),
                  _preset('Каждый день', const [1, 2, 3, 4, 5, 6, 7]),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 348 ? 7 : 4;
                  final gap = columns == 7 ? 2.0 : 6.0;
                  return Wrap(
                    spacing: gap,
                    runSpacing: 6,
                    children: List.generate(7, (index) {
                      final selected = _draft.weekdays.contains(index + 1);
                      return SizedBox(
                        width:
                            ((constraints.maxWidth - gap * (columns - 1)) /
                                    columns)
                                .clamp(48.0, 80.0),
                        child: Semantics(
                          label: '${shortWeekdays[index]}, повторять',
                          button: true,
                          enabled: !_saving,
                          selected: selected,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: _saving
                                ? null
                                : () {
                                    final days = [..._draft.weekdays];
                                    selected
                                        ? days.remove(index + 1)
                                        : days.add(index + 1);
                                    days.sort();
                                    setState(
                                      () => _draft = _draft.copyWith(
                                        weekdays: days,
                                      ),
                                    );
                                  },
                            child: Container(
                              height: 48,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: selected ? morning : panel,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                shortWeekdays[index],
                                style: TextStyle(
                                  color: selected ? ink : muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),
            ],
            const _Heading('Как просыпаться'),
            ...WakePreset.values.map(_wakePreset),
            ListTile(
              key: const ValueKey('preset-custom'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Icon(
                WakePreset.matching(_draft) == null
                    ? Icons.radio_button_checked_rounded
                    : Icons.tune_rounded,
                color: morning,
              ),
              title: const Text('Свои настройки'),
              onTap: _saving ? null : () => _advanced.expand(),
            ),
            const SizedBox(height: 12),
            Text(
              WakePreset.matching(_draft) == null
                  ? 'Свои настройки'
                  : 'Выбрано: ${WakePreset.matching(_draft)!.label}',
              key: const ValueKey('wake-preset-summary'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (WakePreset.matching(_draft) == null) ...[
              const SizedBox(height: 4),
              Text(
                _activeSummary(),
                key: const ValueKey('wake-configuration-summary'),
                style: const TextStyle(color: muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            ExpansionTile(
              key: const ValueKey('alarm-advanced'),
              controller: _advanced,
              initiallyExpanded: WakePreset.matching(_draft) == null,
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              shape: const Border(),
              collapsedShape: const Border(),
              title: const Text('Настроить вручную'),
              subtitle: const Text('Переносы, задания и порядок'),
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Heading('Сколько переносов разрешить'),
                    const Text(
                      'Сколько раз можно отложить звонок перед заданием.',
                      style: TextStyle(color: muted, height: 1.5),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [0, 1, 3]
                          .map(
                            (count) => ChoiceChip(
                              label: Text(
                                count == 0
                                    ? 'Без переносов'
                                    : count == 1
                                    ? '1 перенос'
                                    : '3 переноса',
                              ),
                              selected: _draft.maxSnoozes == count,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _updateDraft(
                                        _draft.copyWith(maxSnoozes: count),
                                      ),
                                    ),
                            ),
                          )
                          .toList(),
                    ),
                    if (_draft.maxSnoozes > 0) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        children: [
                          const Text(
                            'Каждый на',
                            style: TextStyle(color: muted),
                          ),
                          ...[5, 10].map(
                            (minutes) => ChoiceChip(
                              label: Text('$minutes минут'),
                              selected: _draft.snoozeMinutes == minutes,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _draft = _draft.copyWith(
                                        snoozeMinutes: minutes,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'Бюджет переносов: ${_draft.maxSnoozes * _draft.snoozeMinutes} мин. '
                          'Если нажимать сразу, последний звонок — в ${_lastRingLabel()}. '
                          'Если отвечать позже, он тоже сдвинется.',
                          style: const TextStyle(
                            color: morning,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    SwitchListTile.adaptive(
                      key: const ValueKey('move-snooze-button'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Кнопка переноса меняет место'),
                      subtitle: Text(
                        _draft.maxSnoozes == 0 ? 'Сейчас переносы выключены.' : 'После переноса меняются место, размер, цвет и форма. Во время нажатия кнопка остаётся на месте.',
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      value: _draft.moveSnoozeButton,
                      onChanged: _saving || _draft.maxSnoozes == 0
                          ? null
                          : (value) => setState(
                              () => _draft = _draft.copyWith(
                                moveSnoozeButton: value,
                              ),
                            ),
                    ),
                    const _Heading('Задание для пробуждения'),
                    ...ChallengeKind.values.map(
                      (kind) => Semantics(
                        key: ValueKey('challenge-kind-${kind.name}'),
                        button: true,
                        selected: _draft.challengeKind == kind,
                        enabled: !_saving,
                        label: '${kind.label}. ${kind.description}',
                        excludeSemantics: true,
                        onTap: _saving
                            ? null
                            : () => setState(
                                () => _updateDraft(
                                  _draft.copyWith(challengeKind: kind),
                                ),
                              ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(challengeIcon(kind), color: muted),
                          title: Text(kind.label),
                          subtitle: Text(
                            kind.description,
                            style: const TextStyle(color: muted, height: 1.4),
                          ),
                          trailing: Icon(
                            _draft.challengeKind == kind
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _draft.challengeKind == kind
                                ? morning
                                : muted,
                          ),
                          onTap: _saving
                              ? null
                              : () => setState(
                                  () => _updateDraft(
                                    _draft.copyWith(challengeKind: kind),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    if (_draft.challengeKind == ChallengeKind.mixed)
                      _mixSettings(),
                    if (_draft.challengeKind == ChallengeKind.qr ||
                        _draft.mixOrder.contains(ChallengeKind.qr))
                      _qrSettings(),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ChallengeDifficulty.values
                          .map(
                            (level) => ChoiceChip(
                              label: Text(level.label),
                              selected: _draft.difficulty == level,
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _updateDraft(
                                        _draft.copyWith(difficulty: level),
                                      ),
                                    ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      key: const ValueKey('escalate-on-snooze'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Сложнее после переноса'),
                      subtitle: Text(
                        _draft.maxSnoozes == 0 ? 'Сейчас переносы выключены.' : 'Каждый перенос поднимает уровень, максимум — «Нереально».',
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      value: _draft.escalateOnSnooze,
                      onChanged: _saving || _draft.maxSnoozes == 0
                          ? null
                          : (value) => setState(
                              () => _updateDraft(
                                _draft.copyWith(escalateOnSnooze: value),
                              ),
                            ),
                    ),
                    if (_draft.escalateOnSnooze && _draft.maxSnoozes > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        _difficultyPlan(),
                        key: const ValueKey('escalation-plan'),
                        style: const TextStyle(
                          color: morning,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      if (_practiceStages.length > 1) ...[
                        const SizedBox(height: 18),
                        DropdownButtonFormField<int>(
                          key: ValueKey('practice-stage-$_practiceSnoozes'),
                          initialValue: _practiceSnoozes,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Какой звонок попробовать',
                          ),
                          items: _practiceStages
                              .map(
                                (used) => DropdownMenuItem(
                                  value: used,
                                  child: Text(
                                    '${_stageLabel(used)} · ${_draft.difficultyForSnoozes(used).label}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _practiceSnoozes = value ?? 0,
                                ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('practice-alarm'),
                        onPressed: _saving ? null : _practice,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Попробовать задание'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const _Heading('Мелодия'),
            _soundSettings(),
            const _Heading('Название · необязательно'),
            TextField(
              key: const ValueKey('alarm-title'),
              controller: _title,
              maxLength: 50,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Например, утренняя прогулка',
                counterText: '',
              ),
            ),
            if (!widget.controller.device.challengeEnforced)
              const _Note(
                icon: Icons.phone_iphone_rounded,
                text:
                    'На iPhone системный будильник можно остановить без задания. '
                    'Задания доступны после открытия приложения.',
              ),
          ],
        ),
      ),
    ),
  );

  Widget _mixSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Свой порядок заданий'),
        value: _draft.mixOrder.isNotEmpty,
        onChanged: _saving
            ? null
            : (v) => setState(
                () => _draft = _draft.copyWith(
                  mixOrder: v
                      ? [
                          ChallengeKind.math,
                          ChallengeKind.memory,
                          ChallengeKind.stroop,
                          ChallengeKind.sequence,
                          ChallengeKind.mirror,
                          ChallengeKind.captcha,
                          ChallengeKind.flags,
                        ]
                      : [],
                ),
              ),
      ),
      if (_draft.mixOrder.isNotEmpty) ...[
        const Text(
          'Перетаскивай за ручку. Можно повторить один вид несколько раз.',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _draft.mixOrder.length,
          onReorderItem: (old, next) {
            if (_saving) return;
            final items = [..._draft.mixOrder];
            items.insert(next, items.removeAt(old));
            setState(() => _draft = _draft.copyWith(mixOrder: items));
          },
          itemBuilder: (context, index) => ListTile(
            key: ValueKey('mix-$index-${_draft.mixOrder[index].name}'),
            contentPadding: EdgeInsets.zero,
            leading: ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle),
              ),
            ),
            title: Text('${index + 1}. ${_draft.mixOrder[index].label}'),
            trailing: IconButton(
              tooltip: 'Убрать этап',
              onPressed: _saving || _draft.mixOrder.length == 1
                  ? null
                  : () {
                      final items = [..._draft.mixOrder]..removeAt(index);
                      setState(() => _draft = _draft.copyWith(mixOrder: items));
                    },
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ),
        ),
        PopupMenuButton<ChallengeKind>(
          onSelected: (kind) => setState(
            () =>
                _draft = _draft.copyWith(mixOrder: [..._draft.mixOrder, kind]),
          ),
          enabled: !_saving && _draft.mixOrder.length < 12,
          itemBuilder: (_) => ChallengeKind.values
              .where((k) => k != ChallengeKind.mixed)
              .map((k) => PopupMenuItem(value: k, child: Text(k.label)))
              .toList(),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Добавить этап', style: TextStyle(color: morning)),
          ),
        ),
      ],
    ],
  );
  Widget _qrSettings() => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.qr_code_scanner_rounded),
    title: Text(
      _draft.qrValue.isEmpty
          ? 'Зарегистрировать QR-код'
          : 'QR-код зарегистрирован',
    ),
    subtitle: const Text('Например, код в ванной или на кухне'),
    trailing: const Icon(Icons.chevron_right),
    onTap: _saving
        ? null
        : () async {
            final code = await registerQr(context);
            if (code != null && mounted) {
              setState(() => _draft = _draft.copyWith(qrValue: code));
            }
          },
  );
  Widget _soundSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: ValueKey('sound-${_draft.sound}'),
        initialValue: _draft.sound,
        isExpanded: true,
        items:
            {
                  ...const {
                    'system': 'Системный будильник',
                    'classic': 'Классический звонок',
                    'sunrise': 'Мягкий рассвет',
                    'arcade': 'Аркадное утро',
                    'pulse': 'Пульс',
                  },
                  if (_draft.sound.startsWith('file:'))
                    _draft.sound: _draft.soundLabel,
                }.entries
                .map(
                  (e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
        onChanged: _saving
            ? null
            : (v) {
                if (v != null) {
                  setState(() => _draft = _draft.copyWith(sound: v));
                }
              },
        decoration: const InputDecoration(labelText: 'Звук этого будильника'),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Послушать'),
            onPressed: _soundBusy
                ? null
                : () => _soundAction(() async {
                    await NativeExtras.call<void>('previewSound', {
                      'sound': _draft.sound,
                    });
                  }),
          ),
          TextButton.icon(
            icon: const Icon(Icons.audio_file_outlined),
            label: const Text('Выбрать аудиофайл'),
            onPressed: _soundBusy
                ? null
                : () => _soundAction(() async {
                    final value = await NativeExtras.call<Map>('pickSound');
                    if (value != null && mounted) {
                      setState(
                        () => _draft = _draft.copyWith(
                          sound: value['sound'] as String,
                          soundLabel: value['label'] as String,
                        ),
                      );
                    }
                  }),
          ),
        ],
      ),
      if (widget.controller.device.platform == 'ios')
        const Text(
          'Для iPhone берём первые 29 секунд файла.',
          style: TextStyle(color: muted, fontSize: 12),
        ),
    ],
  );
  Future<void> _soundAction(Future<void> Function() action) async {
    setState(() => _soundBusy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PlatformException
              ? e.message
              : 'Не удалось открыть аудио.',
        );
      }
    }
    if (mounted) setState(() => _soundBusy = false);
  }

  Widget _wakePreset(WakePreset preset) {
    final selected = preset.matches(_draft);
    void choose() {
      setState(() => _updateDraft(preset.applyTo(_draft)));
      _advanced.collapse();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        key: ValueKey('preset-${preset.name}'),
        button: true,
        selected: selected,
        enabled: !_saving,
        label: '${preset.label}. ${preset.description}',
        excludeSemantics: true,
        onTap: _saving ? null : choose,
        child: Material(
          color: selected ? panel : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            minVerticalPadding: 8,
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? morning : muted,
            ),
            title: Text(
              preset.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              preset.description,
              style: const TextStyle(color: muted, height: 1.4),
            ),
            onTap: _saving ? null : choose,
          ),
        ),
      ),
    );
  }

  String _activeSummary() {
    final snoozes = _draft.maxSnoozes == 0
        ? 'Без переносов'
        : '${_draft.maxSnoozes} × ${_draft.snoozeMinutes} мин';
    final escalation = _draft.escalateOnSnooze && _draft.maxSnoozes > 0
        ? ' · сложнее после переноса'
        : '';
    return '${_draft.challengeKind.label} · ${_draft.difficulty.label.toLowerCase()} · $snoozes$escalation';
  }

  void _updateDraft(Alarm value) {
    _draft = value;
    if (!_practiceStages.contains(_practiceSnoozes)) _practiceSnoozes = 0;
  }

  List<int> get _practiceStages {
    final stages = [0];
    if (!_draft.escalateOnSnooze) return stages;
    for (var used = 1; used <= _draft.maxSnoozes; used++) {
      if (_draft.difficultyForSnoozes(used) !=
          _draft.difficultyForSnoozes(stages.last)) {
        stages.add(used);
      }
    }
    return stages;
  }

  String _stageLabel(int used) => used == 0
      ? 'Первый звонок'
      : used == 1
      ? 'После 1 переноса'
      : 'После $used переносов';

  String _difficultyPlan() {
    final stages = _practiceStages;
    final plan = stages
        .map((used) {
          final label = used == 0
              ? _stageLabel(used)
              : _stageLabel(used).toLowerCase();
          return '$label: ${_draft.difficultyForSnoozes(used).label}';
        })
        .join(' · ');
    return stages.last < _draft.maxSnoozes
        ? '$plan. Дальше сложность не растёт.'
        : '$plan.';
  }

  String _lastRingLabel() {
    final total =
        _draft.hour * 60 +
        _draft.minute +
        _draft.maxSnoozes * _draft.snoozeMinutes;
    final hour = (total ~/ 60) % 24;
    final minute = total % 60;
    final clock =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return total >= 24 * 60 ? '$clock следующего дня' : clock;
  }

  Widget _preset(String label, List<int> days) => ChoiceChip(
    label: Text(label),
    selected:
        _draft.weekdays.length == days.length &&
        days.every(_draft.weekdays.contains),
    onSelected: _saving
        ? null
        : (_) => setState(() => _draft = _draft.copyWith(weekdays: days)),
  );
}

IconData challengeIcon(ChallengeKind kind) => switch (kind) {
  ChallengeKind.math => Icons.calculate_outlined,
  ChallengeKind.memory => Icons.grid_view_rounded,
  ChallengeKind.stroop => Icons.palette_outlined,
  ChallengeKind.sequence => Icons.format_list_numbered_rounded,
  ChallengeKind.mirror => Icons.flip_rounded,
  ChallengeKind.captcha => Icons.password_rounded,
  ChallengeKind.qr => Icons.qr_code_scanner_rounded,
  ChallengeKind.shake => Icons.vibration_rounded,
  ChallengeKind.maze => Icons.sports_esports_outlined,
  ChallengeKind.flags => Icons.flag_outlined,
  ChallengeKind.mixed => Icons.shuffle_rounded,
};

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: morning.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: morning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
        ),
      ],
    ),
  );
}
