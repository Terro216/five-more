import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';
import 'device_check_screen.dart';
import '../history/history_view.dart';
import '../sleep/bedtime_screen.dart';
import '../sleep/sleep_review.dart';
import '../../services/sleep_journal.dart';
import '../../services/native_extras.dart';
import '../../widgets/time_composer.dart';

class AlarmHome extends StatefulWidget {
  const AlarmHome({super.key, required this.controller});
  final AlarmController controller;
  @override
  State<AlarmHome> createState() => _AlarmHomeState();
}

class _AlarmHomeState extends State<AlarmHome> with WidgetsBindingObserver {
  final _journal = SleepJournal();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _journal.addListener(_journalChanged);
    unawaited(_journal.load());
    NativeExtras.channel.setMethodCallHandler((call) async {
      if (call.method == 'bedtimeOpened') await _checkBedtimeOpen();
    });
    unawaited(_checkBedtimeOpen());
  }

  void _journalChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkBedtimeOpen());
  }

  Future<void> _checkBedtimeOpen() async {
    try {
      final open = await NativeExtras.call<bool>('takeBedtimeOpen');
      if (open == true && mounted) setState(() => _tab = 2);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NativeExtras.channel.setMethodCallHandler(null);
    _journal.removeListener(_journalChanged);
    _journal.dispose();
    super.dispose();
  }

  Future<void> _editTime(Alarm alarm) async {
    final time = await editClock(
      context,
      TimeOfDay(hour: alarm.hour, minute: alarm.minute),
      now: () => controller.now,
      nextAt: (time) => alarm
          .copyWith(hour: time.hour, minute: time.minute, clearOneShotAt: true)
          .nextOccurrence(controller.now),
    );
    if (time == null) return;
    final result = await controller.saveAlarm(
      alarm.copyWith(
        hour: time.hour,
        minute: time.minute,
        clearOneShotAt: true,
      ),
    );
    if (mounted) {
      _message(
        result.ok
            ? 'Время изменено'
            : result.error ?? 'Не удалось изменить время',
      );
    }
  }

  Widget _morningReview() {
    final event = controller.events
        .where(
          (e) =>
              const [
                'dismissed',
                'emergency',
                'emergency_dismissed',
              ].contains(e.type) &&
              !e.alarmId.startsWith('preview:') &&
              !e.at.isAfter(controller.now) &&
              controller.now.difference(e.at) < const Duration(hours: 18),
        )
        .firstOrNull;
    if (!_journal.ready ||
        event == null ||
        _journal.reported(event.occurrenceId)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Как спалось?',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const Text(
            'Оцени утро и оставь вечернему себе голосовое.',
            style: TextStyle(color: muted),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SleepReview(journal: _journal, event: event),
                  ),
                ),
                child: const Text('Оценить утро'),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _tab = 2),
                icon: const Icon(Icons.mic_outlined),
                label: const Text('Записать голос'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await _journal.skip(event.occurrenceId);
                  } catch (_) {
                    if (mounted) {
                      _message('Не удалось сохранить. Попробуй ещё раз.');
                    }
                  }
                },
                child: const Text('Пропустить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _tab = 0;
  ChallengeDifficulty _practiceDifficulty = ChallengeDifficulty.medium;
  AlarmController get controller => widget.controller;

  Future<void> _edit([Alarm? alarm]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AlarmEditor(controller: controller, alarm: alarm),
      ),
    );
    if (saved == true && mounted) {
      _message(
        controller.device.supported
            ? 'Будильник сохранён'
            : 'Черновик сохранён. Срабатывание недоступно.',
      );
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggle(Alarm alarm, bool value) async {
    final result = await controller.setEnabled(alarm, value);
    if (!result.ok && mounted) {
      _message(result.error ?? 'Не удалось изменить будильник');
    }
  }

  Future<void> _delete(Alarm alarm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить будильник?'),
        content: Text('${alarm.timeLabel} · ${alarm.repeatLabel}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await controller.deleteAlarm(alarm.id);
    if (mounted) {
      _message(
        result.ok
            ? 'Будильник удалён'
            : result.error ?? 'Не удалось удалить будильник',
      );
    }
  }

  void _checkDevice([Alarm? alarm]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DeviceCheckScreen(controller: controller, sourceAlarmId: alarm?.id),
      ),
    );
  }

  void _practice(ChallengeKind kind) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChallengeScreen(
          kind: kind,
          difficulty: _practiceDifficulty,
          practice: true,
          onComplete: () => Navigator.of(context).pop(),
          onEmergencyExit: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            _SunMark(size: 30),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'ещё пять',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Проверка телефона',
            onPressed: () => _checkDevice(),
            icon: const Icon(Icons.phonelink_ring_outlined),
          ),
          IconButton(
            tooltip: 'О приложении',
            onPressed: _about,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tab == 0 && !controller.loading)
            SafeArea(
              top: false,
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 700),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('add-alarm'),
                        onPressed: controller.busy || !controller.storageHealthy
                            ? null
                            : () => _edit(),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(
                          controller.alarms.isEmpty
                              ? 'Поставить будильник'
                              : 'Добавить будильник',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.alarm_outlined),
                selectedIcon: Icon(Icons.alarm_rounded),
                label: 'Подъём',
              ),
              NavigationDestination(
                icon: Icon(Icons.extension_outlined),
                selectedIcon: Icon(Icons.extension_rounded),
                label: 'Задания',
              ),
              NavigationDestination(
                icon: Icon(Icons.bedtime_outlined),
                selectedIcon: Icon(Icons.bedtime_rounded),
                label: 'Вечер',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_rounded),
                label: 'История',
              ),
            ],
          ),
        ],
      ),
      body: controller.loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: switch (_tab) {
                  0 => _today(),
                  1 => _challenges(),
                  2 => BedtimeScreen(journal: _journal),
                  _ => HistoryView(
                    events: controller.events,
                    journal: _journal,
                    now: controller.now,
                  ),
                },
              ),
            ),
    ),
  );

  Widget _today() {
    final now = controller.now;
    final next = controller.nextAlarm(now);
    final todaySnoozes = controller.events
        .where(
          (event) =>
              event.type == 'snoozed' &&
              event.at.year == now.year &&
              event.at.month == now.month &&
              event.at.day == now.day,
        )
        .length;
    return RefreshIndicator(
      onRefresh: controller.refreshStatus,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Text(
            _dayTitle(now),
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (next != null) _nextCard(next, now) else _emptyCard(),
          const SizedBox(height: 12),
          _deviceCard(),
          _morningReview(),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _InfoCard(
                icon: Icons.error_outline_rounded,
                title: 'Нужно проверить',
                text: controller.error!,
                color: const Color(0xFFFFB4AB),
              ),
            ),
          if (todaySnoozes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _InfoCard(
                icon: Icons.snooze_rounded,
                title: 'Сегодня: $todaySnoozes ${_times(todaySnoozes)}',
                text: 'Столько переносов записал будильник. Подробности — в истории.',
              ),
            ),
          if (controller.alarms.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Мои будильники',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${controller.alarms.length}',
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...controller.alarms.map(_alarmCard),
          ],
          if (!controller.device.challengeEnforced)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: _InfoCard(
                icon: Icons.phone_iphone_rounded,
                title: 'Особенность iPhone',
                text:
                    'Системный будильник можно остановить без задания. '
                    'Чтобы пройти задание, откройте приложение.',
              ),
            ),
        ],
      ),
    );
  }

  Widget _nextCard(Alarm alarm, DateTime now) {
    final nextAt = controller.nextTime(alarm, now);
    final duration = nextAt.difference(now);
    final totalMinutes = (duration.inSeconds / 60).ceil().clamp(0, 10000000);
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    final left = hours > 0
        ? '$hours ч ${minutes.toString().padLeft(2, '0')} мин'
        : '$minutes мин';
    final time = Text(
      '${nextAt.hour.toString().padLeft(2, '0')}:${nextAt.minute.toString().padLeft(2, '0')}',
      style: const TextStyle(
        fontSize: 56,
        fontWeight: FontWeight.w400,
        height: 1.1,
        letterSpacing: -1.5,
        color: morning,
      ),
    );
    final detail = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _relativeDay(nextAt, now),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'До будильника $left',
          style: const TextStyle(color: muted, fontSize: 13),
        ),
      ],
    );
    return Material(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const ValueKey('next-alarm'),
        onTap: controller.busy ? null : () => _editTime(alarm),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final expandedText =
                  MediaQuery.textScalerOf(context).scale(16) > 20;
              if (constraints.maxWidth < 300 || expandedText) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(fit: BoxFit.scaleDown, child: time),
                    const SizedBox(height: 8),
                    detail,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: time,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: detail),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _emptyCard() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.alarms.isEmpty
              ? 'Утро начинается с одного будильника.'
              : 'Ближайший подъём пока не назначен.',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: -.6,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          controller.alarms.isEmpty
              ? 'Выбери время, переносы и задание для пробуждения.'
              : 'Включи один из будильников или добавь новый.',
          style: const TextStyle(color: muted, height: 1.5, fontSize: 14),
        ),
      ],
    ),
  );

  Widget _deviceCard() {
    final device = controller.device;
    final check = controller.deviceCheck;
    final missingPermission =
        !device.notifications ||
        !device.exactAlarms ||
        !device.fullScreenIntent;
    if (device.supported &&
        !missingPermission &&
        device.alarmVolume != 0 &&
        device.recoveryError == null &&
        device.error == null &&
        check?.heard == true &&
        check?.pending != true) {
      return const SizedBox.shrink();
    }
    final title = !device.supported
        ? 'Режим знакомства'
        : missingPermission
        ? 'Проверь разрешения телефона'
        : device.alarmVolume == 0
        ? 'Звук будильника выключен'
        : device.recoveryError != null
        ? 'Расписание требует восстановления'
        : device.error != null
        ? 'Не удалось проверить телефон'
        : check?.pending == true
        ? 'Проверка срабатывания начата'
        : check?.heard == true
        ? 'Ты подтвердил звук при проверке'
        : check?.heard == false
        ? 'При проверке звук не прозвучал'
        : 'Телефон ещё не проверен';
    final text = !device.supported
        ? 'Здесь можно настроить черновик и попробовать задания.'
        : missingPermission
        ? 'Часть разрешений выключена. Проверь их перед следующим утром.'
        : device.alarmVolume == 0
        ? 'Подними громкость будильника и повтори проверку.'
        : device.recoveryError != null
        ? 'Открой проверку телефона и повтори восстановление расписания.'
        : device.error != null
        ? device.error!
        : check?.pending == true
        ? 'Вернись к проверке и отметь, прозвучал ли будильник.'
        : check?.heard == true
        ? 'После изменения настроек повтори проверку.'
        : check?.heard == false
        ? 'Посмотри настройки звука и разрешения, затем попробуй ещё раз.'
        : 'Проверь звук с заблокированным экраном.';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('home-device-check'),
        onTap: () => _checkDevice(),
        borderRadius: BorderRadius.circular(12),
        child: Semantics(
          button: true,
          label: device.supported ? 'Проверка телефона' : 'Что доступно здесь',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    !device.supported
                        ? Icons.visibility_outlined
                        : Icons.phonelink_ring_rounded,
                    color: morning,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        text,
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _alarmCard(Alarm alarm) => Padding(
    key: ValueKey('alarm-card-${alarm.id}'),
    padding: const EdgeInsets.only(bottom: 10),
    child: Dismissible(
      key: ValueKey('swipe-alarm-${alarm.id}'),
      direction: controller.busy
          ? DismissDirection.none
          : DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: const Color(0xFF572D2B),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline_rounded),
      ),
      confirmDismiss: (_) async {
        await _delete(alarm);
        return false;
      },
      child: Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: 'Удалить будильник'): () =>
              _delete(alarm),
        },
        child: Material(
          color: panel,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: controller.busy ? null : () => _edit(alarm),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alarm.displayTitle,
                    key: ValueKey('alarm-name-${alarm.id}'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: InkWell(
                            key: ValueKey('alarm-time-${alarm.id}'),
                            onTap: controller.busy
                                ? null
                                : () => _editTime(alarm),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                alarm.timeLabel,
                                style: TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.w400,
                                  color: alarm.enabled ? foreground : muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        label:
                            '${alarm.timeLabel}, ${alarm.enabled ? 'выключить' : 'включить'} будильник',
                        child: Switch(
                          key: ValueKey('alarm-toggle-${alarm.id}'),
                          value: alarm.enabled,
                          onChanged:
                              controller.busy || !controller.device.supported
                              ? null
                              : (value) => _toggle(alarm, value),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    alarm.repeatLabel,
                    style: const TextStyle(color: muted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Text(
                        '${alarm.challengeKind.label} · ${alarm.difficulty.label.toLowerCase()}',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                      Text(
                        alarm.maxSnoozes == 0
                            ? 'Без переносов'
                            : '${alarm.maxSnoozes} × ${alarm.snoozeMinutes} мин',
                        style: const TextStyle(color: morning, fontSize: 12),
                      ),
                      if (alarm.escalateOnSnooze && alarm.maxSnoozes > 0)
                        const Text(
                          'Сложнее после переноса',
                          style: TextStyle(color: morning, fontSize: 12),
                        ),
                      if (!controller.device.supported)
                        const Text(
                          'Черновик',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _challenges() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      const Text(
        'Разбуди голову.',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -.6,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Попробуй задания заранее. В тренировке будильник не звучит.',
        style: TextStyle(color: muted, height: 1.4, fontSize: 14),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: ChallengeDifficulty.values
            .map(
              (level) => ChoiceChip(
                label: Text(level.label),
                selected: _practiceDifficulty == level,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => _practiceDifficulty = level),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 12),
      ...ChallengeKind.values.map(
        (kind) => ListTile(
          key: ValueKey('practice-kind-${kind.name}'),
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: 8,
          leading: Icon(challengeIcon(kind), color: morning),
          title: Text(
            kind.label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            kind.description,
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          trailing: const ExcludeSemantics(
            child: Icon(Icons.play_arrow_rounded, color: morning),
          ),
          onTap: () => _practice(kind),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Text(
          'Сложность можно менять отдельно для каждого будильника. '
          'Аварийное отключение всегда доступно.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.5),
        ),
      ),
    ],
  );

  Future<void> _about() async {
    final version = await NativeExtras.version();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ещё пять'),
        content: Text(
          'Версия · $version\n\n'
          'Простой будильник, ограниченные переносы и задания для пробуждения.\n\n'
          'Без регистрации и рекламы. Записи, оценки сна и история остаются на телефоне. Фразы из интернета — только по желанию.\n\n'
          'Перед первым утром проверь срабатывание на своём телефоне. '
          'После принудительной остановки приложения открой его снова.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _relativeDay(DateTime date, DateTime now) {
  if (_sameDay(date, now)) return 'Сегодня';
  if (_sameDay(date, DateTime(now.year, now.month, now.day + 1))) {
    return 'Завтра';
  }
  const weekdays = [
    'В понедельник',
    'Во вторник',
    'В среду',
    'В четверг',
    'В пятницу',
    'В субботу',
    'В воскресенье',
  ];
  return weekdays[date.weekday - 1];
}

String _dayTitle(DateTime date) {
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  const weekdays = [
    'Понедельник',
    'Вторник',
    'Среда',
    'Четверг',
    'Пятница',
    'Суббота',
    'Воскресенье',
  ];
  return '${weekdays[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}';
}

String _times(int count) =>
    count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14)
    ? 'переноса'
    : count % 10 == 1 && count % 100 != 11
    ? 'перенос'
    : 'переносов';

class _SunMark extends StatelessWidget {
  const _SunMark({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: morning,
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(Icons.wb_twilight_rounded, color: ink, size: size * .65),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.text,
    this.color = morning,
  });
  final IconData icon;
  final String title;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: .12)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                text,
                style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
