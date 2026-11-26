import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../l10n/strings.dart';
import '../../models/alarm.dart';
import '../../models/background_frame.dart';
import '../../services/native_extras.dart';
import '../../widgets/alarm_background.dart';
import '../../widgets/exact_slider.dart';
import '../../widgets/time_composer.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import '../challenges/phrase_settings.dart';
import '../challenges/physical_tasks.dart';
import 'background_editor.dart';

class AlarmEditor extends StatefulWidget {
  const AlarmEditor({
    super.key,
    required this.controller,
    this.alarm,
    this.initialTime,
  });
  final AlarmController controller;
  final Alarm? alarm;
  final TimeOfDay? initialTime;

  @override
  State<AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<AlarmEditor> with WidgetsBindingObserver {
  bool _allowPop = false;
  late String _initial;
  String get _draftKey => 'five_more.editor.${widget.alarm?.id ?? "new"}';
  bool get _dirty =>
      jsonEncode(_draft.toJson()) != _initial ||
      _title.text != (widget.alarm?.title ?? '');
  late Alarm _draft;
  late final TextEditingController _title;
  bool _saving = false;
  int _practiceSnoozes = 0;
  String? _error;
  final _invalidNumbers = <String>{};
  void _numberValidity(String key, bool valid) => setState(() {
    valid ? _invalidNumbers.remove(key) : _invalidNumbers.add(key);
  });
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
    _initial = jsonEncode(_draft.toJson());
    final time = widget.initialTime;
    if (time != null &&
        (time.hour != _draft.hour || time.minute != _draft.minute)) {
      _draft = _draft.copyWith(
        hour: time.hour,
        minute: time.minute,
        clearOneShotAt: true,
      );
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreDraft());
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _restoreDraft() async {
    // An explicit time from the quick editor takes precedence over an older draft.
    if (widget.initialTime != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw == null || !mounted || _dirty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // A draft cannot overwrite edits made since it was saved.
      if (widget.alarm != null && data['base'] != _initial) return;
      final restored = Alarm.fromJson(
        Map<String, dynamic>.from(data['alarm'] as Map),
      );
      if (widget.alarm == null &&
          widget.controller.alarms.any((a) => a.id == restored.id)) {
        return;
      }
      setState(() {
        _draft = restored;
        _title.text = _draft.title;
        _nap = data['nap'] == true;
        _napMinutes = data['napMinutes'] as int? ?? 20;
      });
    } catch (_) {
      /* Leave the saved draft untouched. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _dirty) {
      unawaited(
        SharedPreferences.getInstance()
            .then(
              (prefs) => prefs.setString(
                _draftKey,
                jsonEncode({
                  'base': _initial,
                  'alarm': _draft.copyWith(title: _title.text).toJson(),
                  'nap': _nap,
                  'napMinutes': _napMinutes,
                }),
              ),
            )
            .catchError((Object _) => false),
      );
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    if (_dirty || _nap) {
      await _save(enable: false);
    } else {
      setState(() => _allowPop = true);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();

    _clock?.cancel();
    if (NativeExtras.available) {
      unawaited(NativeExtras.call<void>('stopAudio').catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _save({bool enable = true}) async {
    if (_invalidNumbers.isNotEmpty) {
      setState(() => _error = appStrings.checkTheNumbersInYourSettings);
      return;
    }
    if (_saving) return;
    if (!_nap && !_timeValid) {
      setState(() => _error = appStrings.finishEnteringTheTime);
      return;
    }
    if (_draft.requiresChallenge &&
        (_draft.challengeKind == ChallengeKind.qr ||
            (_draft.challengeKind == ChallengeKind.mixed &&
                _draft.mixOrder.contains(ChallengeKind.qr))) &&
        _draft.qrValue.isEmpty) {
      setState(() => _error = appStrings.registerAQrCodeFirst);
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
        enabled: enable || (widget.alarm?.enabled ?? true),
      ),
    );
    if (!mounted) return;
    if (result.ok) {
      try {
        await (await SharedPreferences.getInstance()).remove(_draftKey);
      } catch (_) {
        /* Native scheduling has already succeeded. */
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
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

  Future<void> _frameBackground({String? name}) async {
    final selected = name ?? _draft.background;
    final frame = await Navigator.of(context).push<BackgroundFrame>(
      MaterialPageRoute(
        builder: (_) => BackgroundEditor(
          name: selected,
          alarm: _draft,
          initial: name == null
              ? _draft.backgroundFrame
              : const BackgroundFrame(),
        ),
      ),
    );
    if (frame != null && mounted) {
      setState(
        () => _draft = _draft.copyWith(
          background: selected,
          backgroundFrame: frame,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _leave),
        title: Text(
          widget.alarm == null
              ? context.strings.newAlarm
              : context.strings.editAlarm,
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
                      style: TextStyle(color: context.palette.red, height: 1.4),
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
                            ? context.strings.done
                            : context.strings.saveDraft,
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
                _Note(
                  icon: Icons.info_outline_rounded,
                  text: context.strings.draftPreviewNotice,
                ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(context.strings.alarm),
                  ),
                  ButtonSegment(value: true, label: Text(context.strings.nap)),
                ],
                selected: {_nap},
                onSelectionChanged: _saving
                    ? null
                    : (v) => setState(() {
                        _nap = v.single;
                        if (!_nap) {
                          _invalidNumbers.remove('nap');
                          _draft = _draft.copyWith(clearOneShotAt: true);
                        }
                      }),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _nap
                      ? context.strings.ringsAt(
                          clockLabel(
                            TimeOfDay.fromDateTime(
                              widget.controller.now.add(
                                Duration(minutes: _napMinutes),
                              ),
                            ),
                          ),
                        )
                      : context.strings.ringsIn(
                          remainingLabel(
                            _draft.nextOccurrence(widget.controller.now),
                            widget.controller.now,
                          ),
                        ),
                  key: const ValueKey('alarm-time-remaining'),
                  style: TextStyle(
                    color: context.palette.morning,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_nap) ...[
                ExactSlider(
                  key: const ValueKey('nap-minutes'),
                  label: context.strings.nap,
                  unit: context.strings.min,
                  value: _napMinutes,
                  min: 1,
                  max: 1440,
                  sliderMax: 180,
                  enabled: !_saving,
                  onValidityChanged: (v) => _numberValidity('nap', v),
                  onChanged: (v) => setState(() => _napMinutes = v),
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
                _Heading(context.strings.repeat),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _preset(context.strings.once, const []),
                    _preset(context.strings.weekdays, const [1, 2, 3, 4, 5]),
                    _preset(context.strings.everyDay, const [
                      1,
                      2,
                      3,
                      4,
                      5,
                      6,
                      7,
                    ]),
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
                      children: List.generate(7, (position) {
                        final index = (firstWeekdayIndex + position) % 7;
                        final selected = _draft.weekdays.contains(index + 1);
                        return SizedBox(
                          width:
                              ((constraints.maxWidth - gap * (columns - 1)) /
                                      columns)
                                  .clamp(48.0, 80.0),
                          child: Semantics(
                            label: context.strings.repeatOnWeekday(
                              shortWeekdays[index],
                            ),
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
                                  color: selected
                                      ? context.palette.morning
                                      : context.palette.panel,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  shortWeekdays[index],
                                  style: TextStyle(
                                    color: selected
                                        ? context.palette.ink
                                        : context.palette.muted,
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
              const SizedBox(height: 24),
              SegmentedButton<String>(
                key: const ValueKey('dismissal-mode'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: 'normal',
                    label: Text(context.strings.standardAlarm),
                  ),
                  ButtonSegment(
                    value: 'challenge',
                    label: Text(context.strings.withChallenge),
                  ),
                ],
                selected: {_draft.dismissalMode},
                onSelectionChanged: _saving
                    ? null
                    : (v) => setState(() {
                        _draft = _draft.copyWith(dismissalMode: v.single);
                      }),
              ),
              if (_draft.requiresChallenge)
                Column(
                  key: const ValueKey('alarm-challenge'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Heading(context.strings.wakeUpChallenge),
                    if (_draft.challengeKind == ChallengeKind.mirror ||
                        _draft.challengeKind == ChallengeKind.mixed)
                      const PhraseSettings(),
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
                          leading: Icon(
                            challengeIcon(kind),
                            color: context.palette.muted,
                          ),
                          title: Text(kind.label),
                          subtitle: Text(
                            kind.description,
                            style: TextStyle(
                              color: context.palette.muted,
                              height: 1.4,
                            ),
                          ),
                          trailing: Icon(
                            _draft.challengeKind == kind
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _draft.challengeKind == kind
                                ? context.palette.morning
                                : context.palette.muted,
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
                      title: Text(context.strings.harderAfterEachSnooze),
                      subtitle: Text(
                        _draft.snoozeBudget == 0
                            ? context.strings.snoozingIsTurnedOff
                            : context
                                  .strings
                                  .eachSnoozeRaisesTheDifficultyByOne,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      value: _draft.escalateOnSnooze,
                      onChanged: _saving || _draft.snoozeBudget == 0
                          ? null
                          : (value) => setState(
                              () => _updateDraft(
                                _draft.copyWith(escalateOnSnooze: value),
                              ),
                            ),
                    ),
                    if (_draft.escalateOnSnooze && _draft.snoozeBudget > 0) ...[
                      if (_practiceStages.length > 1) ...[
                        const SizedBox(height: 18),
                        DropdownButtonFormField<int>(
                          key: ValueKey('practice-stage-$_practiceSnoozes'),
                          initialValue: _practiceSnoozes,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: context.strings.chooseARingToTry,
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
                        label: Text(context.strings.tryChallenge),
                      ),
                    ),
                  ],
                ),
              Column(
                key: const ValueKey('alarm-snoozes'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Heading(context.strings.snooze),
                  ExactSlider(
                    label: context.strings.totalSnoozeTime,
                    unit: context.strings.min,
                    key: const ValueKey('snooze-budget'),
                    value: _draft.snoozeBudget,
                    min: 0,
                    max: 300,
                    enabled: !_saving,
                    onValidityChanged: (v) => _numberValidity('budget', v),
                    onChanged: (v) => setState(() {
                      if (v == 0 || v < _draft.snoozeMinutes) {
                        _invalidNumbers.remove('snooze');
                      }
                      _draft = _draft.copyWith(
                        snoozeBudgetMinutes: v,
                        snoozeMinutes: v == 0
                            ? _draft.snoozeMinutes
                            : _draft.snoozeMinutes.clamp(1, v.clamp(1, 30)),
                      );
                    }),
                  ),
                  if (_draft.snoozeBudget > 0)
                    ExactSlider(
                      label: context.strings.snoozeDuration,
                      unit: context.strings.min,
                      key: const ValueKey('snooze-minutes'),
                      value: _draft.snoozeMinutes,
                      min: 1,
                      max: 30,
                      enabled: !_saving,
                      onValidityChanged: (v) => _numberValidity('snooze', v),
                      onChanged: (v) => setState(() {
                        if (v > _draft.snoozeBudget) {
                          _invalidNumbers.remove('budget');
                        }
                        _draft = _draft.copyWith(
                          snoozeMinutes: v,
                          snoozeBudgetMinutes: v > _draft.snoozeBudget
                              ? v
                              : _draft.snoozeBudget,
                        );
                      }),
                    ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('move-snooze-button'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.strings.hideTheSnoozeButton),
                    subtitle: Text(context.strings.movingSnoozeExplanation),
                    value: _draft.moveSnoozeButton,
                    onChanged: _saving || _draft.snoozeBudget == 0
                        ? null
                        : (v) => setState(
                            () => _draft = _draft.copyWith(moveSnoozeButton: v),
                          ),
                  ),
                ],
              ),
              _Heading(context.strings.soundAndVibration),
              _soundSettings(),
              _Heading(context.strings.alarmBackground),
              if (_draft.background.isNotEmpty)
                SizedBox(
                  height: 180,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: MediaQuery.sizeOf(context).aspectRatio,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AlarmBackground(
                          name: _draft.background,
                          frame: _draft.backgroundFrame,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _draft.timeLabel,
                                  style: const TextStyle(fontSize: 48),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    key: const ValueKey('pick-alarm-background'),
                    onPressed: _saving || _soundBusy
                        ? null
                        : () => _soundAction(() async {
                            final name = await NativeExtras.call<String>(
                              'pickBackground',
                            );
                            if (mounted && validBackgroundName(name)) {
                              await _frameBackground(name: name);
                            }
                          }),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      _draft.background.isEmpty
                          ? context.strings.choosePhoto
                          : context.strings.replacePhoto,
                    ),
                  ),
                  if (_draft.background.isNotEmpty)
                    TextButton.icon(
                      key: const ValueKey('edit-background-frame'),
                      onPressed: _saving || _soundBusy
                          ? null
                          : () => _soundAction(() => _frameBackground()),
                      icon: const Icon(Icons.crop),
                      label: Text(context.strings.adjustPhoto),
                    ),
                  if (_draft.background.isNotEmpty)
                    TextButton(
                      onPressed: _saving || _soundBusy
                          ? null
                          : () => setState(
                              () => _draft = _draft.copyWith(
                                background: '',
                                backgroundFrame: const BackgroundFrame(),
                              ),
                            ),
                      child: Text(context.strings.removeBackground),
                    ),
                ],
              ),
              Text(
                widget.controller.device.platform == 'ios'
                    ? context.strings.iphonePhotoPrivacy
                    : context.strings.yourPhotoStaysOnThisPhone,
                style: TextStyle(fontSize: 12, color: context.palette.muted),
              ),
              _Heading(context.strings.nameOptional),
              TextField(
                key: const ValueKey('alarm-title'),
                controller: _title,
                maxLength: 50,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: context.strings.eGMorningWalk,
                  counterText: '',
                ),
              ),
              if (_nap || _draft.weekdays.isEmpty)
                SwitchListTile.adaptive(
                  key: const ValueKey('delete-after-dismiss'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.strings.delete),
                  subtitle: Text(context.strings.afterDismissal),
                  value: _draft.deleteAfterDismiss,
                  onChanged: _saving
                      ? null
                      : (v) => setState(
                          () => _draft = _draft.copyWith(
                            weekdays: _nap ? const [] : _draft.weekdays,
                            deleteAfterDismiss: v,
                          ),
                        ),
                ),
              if (_draft.requiresChallenge &&
                  !widget.controller.device.challengeEnforced)
                _Note(
                  icon: Icons.phone_iphone_rounded,
                  text: context.strings.iosChallengeNotice,
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _mixSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(appStrings.customChallengeOrder),
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
        Text(
          appStrings.reorderStagesHint,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
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
              tooltip: context.strings.removeStage,
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
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              appStrings.addStage,
              style: TextStyle(color: context.palette.morning),
            ),
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
          ? appStrings.registerQrCode
          : appStrings.qrCodeRegistered,
    ),
    subtitle: Text(appStrings.qrLocationHint),
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
      if (widget.controller.device.platform != 'ios') ...[
        ExactSlider(
          key: const ValueKey('volume-ramp'),
          label: appStrings.fadeInDuration,
          unit: appStrings.s,
          value: _draft.volumeRampSeconds,
          min: 0,
          max: 60,
          enabled: !_saving,
          onValidityChanged: (v) => _numberValidity('ramp', v),
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(volumeRampSeconds: v)),
        ),
        SwitchListTile.adaptive(
          title: Text(appStrings.vibration),
          value: _draft.vibration,
          onChanged: _saving
              ? null
              : (v) => setState(() => _draft = _draft.copyWith(vibration: v)),
        ),
        const SizedBox(height: 16),
      ],
      DropdownButtonFormField<String>(
        key: ValueKey('sound-${_draft.sound}'),
        initialValue: _draft.sound,
        isExpanded: true,
        items:
            {
                  ...{
                    'system': appStrings.systemAlarmSound,
                    'classic': appStrings.classicRing,
                    'sunrise': appStrings.gentleSunrise,
                    'arcade': appStrings.arcadeMorning,
                    'pulse': appStrings.pulse,
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
                  setState(
                    () => _draft = _draft.copyWith(
                      sound: v,
                      soundLabel:
                          {
                            'system': appStrings.systemAlarmSound,
                            'classic': appStrings.classicRing,
                            'sunrise': appStrings.gentleSunrise,
                            'arcade': appStrings.arcadeMorning,
                            'pulse': appStrings.pulse,
                          }[v] ??
                          _draft.soundLabel,
                    ),
                  );
                }
              },
        decoration: InputDecoration(labelText: appStrings.alarmSound),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(appStrings.listen),
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
            label: Text(appStrings.chooseAudioFile),
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
        Text(
          appStrings.iosAudioLengthHint,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
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
              : appStrings.couldntOpenTheFileTryAgain,
        );
      }
    }
    if (mounted) setState(() => _soundBusy = false);
  }

  void _updateDraft(Alarm value) {
    _draft = value;
    if (!_practiceStages.contains(_practiceSnoozes)) _practiceSnoozes = 0;
  }

  List<int> get _practiceStages {
    final stages = [0];
    if (!_draft.escalateOnSnooze) return stages;
    for (var used = 1; used <= _draft.snoozeBudget.clamp(0, 3); used++) {
      if (_draft.difficultyForSnoozes(used) !=
          _draft.difficultyForSnoozes(stages.last)) {
        stages.add(used);
      }
    }
    return stages;
  }

  String _stageLabel(int used) => used == 0
      ? appStrings.firstRing
      : used == 1
      ? appStrings.after1Snooze
      : appStrings.afterSnoozes(used);

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
      color: context.palette.morning.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: context.palette.morning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
        ),
      ],
    ),
  );
}
