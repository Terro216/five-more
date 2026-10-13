import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';

class AlarmHome extends StatefulWidget {
  const AlarmHome({super.key, required this.controller});
  final AlarmController controller;
  @override
  State<AlarmHome> createState() => _AlarmHomeState();
}

class _AlarmHomeState extends State<AlarmHome> {
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

  Future<void> _test(Alarm alarm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Проверить будильник?'),
        content: const Text(
          'Сейчас запустится короткая проверка с настоящим звуком '
          'и выбранным заданием. Основное расписание сохранится.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Проверить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await controller.testAlarm(alarm.id);
    if (mounted) {
      _message(
        result.ok
            ? 'Проверочный будильник сработает через 5 секунд.'
            : result.error ?? 'Не удалось запустить проверку',
      );
    }
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
            Text(
              'ещё пять',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                letterSpacing: -.8,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'О приложении',
            onPressed: _about,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: NavigationBar(
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
            icon: Icon(Icons.history_rounded),
            label: 'История',
          ),
        ],
      ),
      floatingActionButton:
          _tab == 0 && controller.alarms.isNotEmpty && !controller.loading
          ? FloatingActionButton.extended(
              onPressed: controller.busy || !controller.storageHealthy
                  ? null
                  : () => _edit(),
              backgroundColor: morning,
              foregroundColor: ink,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Будильник'),
            )
          : null,
      body: controller.loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: switch (_tab) {
                  0 => _today(),
                  1 => _challenges(),
                  _ => _history(),
                },
              ),
            ),
    ),
  );

  Widget _today() {
    final now = DateTime.now();
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
        children: [
          Text(
            _dayTitle(now),
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (next != null) _nextCard(next, now) else _emptyCard(),
          const SizedBox(height: 18),
          _deviceCard(),
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
            const SizedBox(height: 30),
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
    final totalMinutes = (duration.inSeconds / 60).ceil();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    final left = hours > 0
        ? '$hours ч ${minutes.toString().padLeft(2, '0')} мин'
        : '$minutes мин';
    return InkWell(
      onTap: () => _edit(alarm),
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF374330), Color(0xFF222D21)],
          ),
          border: Border.all(color: morning.withValues(alpha: .18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wb_twilight_rounded, size: 20, color: morning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _relativeDay(nextAt, now).toUpperCase(),
                    style: const TextStyle(
                      color: morning,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.7,
                    ),
                  ),
                ),
                const Icon(Icons.arrow_outward_rounded, size: 18, color: muted),
              ],
            ),
            const SizedBox(height: 14),
            FittedBox(
              alignment: Alignment.centerLeft,
              child: Text(
                '${nextAt.hour.toString().padLeft(2, '0')}:${nextAt.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontSize: 86,
                  fontWeight: FontWeight.w300,
                  height: 1.1,
                  letterSpacing: -5,
                  color: Color(0xFFFFE2A2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              alarm.displayTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'До будильника $left',
              style: const TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Pill(
                  icon: challengeIcon(alarm.challengeKind),
                  text: alarm.challengeKind.label,
                ),
                _Pill(
                  icon: Icons.snooze_rounded,
                  text: alarm.maxSnoozes == 0
                      ? 'Без переносов'
                      : '${alarm.maxSnoozes} × ${alarm.snoozeMinutes} мин',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() => Container(
    padding: const EdgeInsets.all(26),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(30),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SunMark(size: 58),
        const SizedBox(height: 24),
        Text(
          controller.alarms.isEmpty
              ? 'Утро начинается\nс одного будильника.'
              : 'Ближайший подъём\nпока не назначен.',
          style: const TextStyle(
            fontSize: 29,
            fontWeight: FontWeight.w600,
            height: 1.15,
            letterSpacing: -.8,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Выбери время, оставь себе пару переносов\nи найди задание, которое разбудит.',
          style: TextStyle(color: muted, height: 1.5, fontSize: 14),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: controller.busy || !controller.storageHealthy
              ? null
              : () => _edit(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Поставить будильник'),
        ),
      ],
    ),
  );

  Widget _deviceCard() {
    final device = controller.device;
    if (!device.supported) {
      return _InfoCard(
        icon: Icons.visibility_outlined,
        title: 'Режим знакомства',
        text:
            device.error ??
            'Можно настроить черновик и попробовать задания. '
                'Настоящие будильники на этой платформе недоступны.',
      );
    }
    if (device.needsAttention) {
      final missing = [
        if (!device.notifications) 'уведомления',
        if (!device.exactAlarms) 'точное срабатывание',
        if (!device.fullScreenIntent) 'экран поверх блокировки',
      ];
      return _InfoCard(
        icon: Icons.notifications_active_outlined,
        title: device.canSchedule
            ? 'Проверь экран будильника'
            : 'Разреши будильнику срабатывать',
        text:
            'Нужно включить: ${missing.join(', ')}. '
            'Система может запросить разрешения по очереди.',
        action: TextButton(
          onPressed: controller.requestPermissions,
          child: const Text('Открыть разрешения'),
        ),
      );
    }
    return const _InfoCard(
      icon: Icons.check_circle_outline_rounded,
      title: 'Системные разрешения включены',
      text: 'Звук и расписание хранятся на телефоне. Интернет для подъёма не нужен.',
      color: Color(0xFFADCCA4),
    );
  }

  Widget _alarmCard(Alarm alarm) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: panel,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: controller.busy ? null : () => _edit(alarm),
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alarm.timeLabel,
                      style: TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -1,
                        color: alarm.enabled ? Colors.white : muted,
                      ),
                    ),
                  ),
                  Semantics(
                    label:
                        '${alarm.timeLabel}, ${alarm.enabled ? 'выключить' : 'включить'} будильник',
                    child: Switch(
                      value: alarm.enabled,
                      onChanged: controller.busy || !controller.device.supported
                          ? null
                          : (value) => _toggle(alarm, value),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Действия с будильником',
                    enabled: !controller.busy,
                    onSelected: (action) {
                      if (action == 'edit') _edit(alarm);
                      if (action == 'test') _test(alarm);
                      if (action == 'delete') _delete(alarm);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Настроить'),
                      ),
                      if (controller.device.supported)
                        const PopupMenuItem(
                          value: 'test',
                          child: Text('Проверить срабатывание'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить'),
                      ),
                    ],
                  ),
                ],
              ),
              Text(
                '${alarm.repeatLabel}${alarm.title.isEmpty ? '' : ' · ${alarm.title}'}',
                style: const TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    '${alarm.challengeKind.label} · ${alarm.difficulty.label.toLowerCase()}',
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                  Text(
                    alarm.maxSnoozes == 0
                        ? 'Без переносов'
                        : '${alarm.maxSnoozes} × ${alarm.snoozeMinutes} мин',
                    style: const TextStyle(color: morning, fontSize: 11),
                  ),
                  if (!controller.device.supported)
                    const Text(
                      'Черновик',
                      style: TextStyle(color: muted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _challenges() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
    children: [
      const Text(
        'Разбуди голову.',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -.8,
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Попробуй сейчас, чтобы утром знать правила.\nЗвук будильника в тренировке не включается.',
        style: TextStyle(color: muted, height: 1.5),
      ),
      const SizedBox(height: 22),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: ChallengeDifficulty.values
            .map(
              (level) => ChoiceChip(
                label: Text(level.label),
                selected: _practiceDifficulty == level,
                onSelected: (_) => setState(() => _practiceDifficulty = level),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 22),
      ...ChallengeKind.values.map(
        (kind) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: panel,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: () => _practice(kind),
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: morning.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(challengeIcon(kind), color: morning),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.arrow_outward_rounded,
                          color: muted,
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      kind.label,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      kind.description,
                      style: const TextStyle(color: muted, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    const Row(
                      children: [
                        Icon(
                          Icons.play_arrow_rounded,
                          color: morning,
                          size: 18,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Попробовать',
                          style: TextStyle(
                            color: morning,
                            fontWeight: FontWeight.w700,
                          ),
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
      const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Text(
          'Сложность можно менять отдельно для каждого будильника. '
          'Аварийное отключение всегда доступно.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.5),
        ),
      ),
    ],
  );

  Widget _history() {
    final events = controller.events;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
      children: [
        const Text(
          'Как прошло утро',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            letterSpacing: -.8,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Срабатывания, переносы и отключения.\nТолько события будильника, без оценки сна.',
          style: TextStyle(color: muted, height: 1.5),
        ),
        const SizedBox(height: 28),
        if (events.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(26),
            ),
            child: const Column(
              children: [
                Icon(Icons.wb_twilight_rounded, size: 52, color: morning),
                SizedBox(height: 20),
                Text(
                  'Первое утро ещё впереди',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 10),
                Text(
                  'После срабатывания здесь появится история.\nТренировки в неё не записываются.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, height: 1.5),
                ),
              ],
            ),
          ),
        for (var index = 0; index < events.length; index++) ...[
          if (index == 0 || !_sameDay(events[index - 1].at, events[index].at))
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 14),
              child: Text(
                _dayTitle(events[index].at),
                style: const TextStyle(
                  color: morning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _eventTile(events[index]),
        ],
        if (events.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Text(
              'Последние 500 событий хранятся только на этом устройстве.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
          ),
      ],
    );
  }

  Widget _eventTile(AlarmEvent event) {
    final clock =
        '${event.at.hour.toString().padLeft(2, '0')}:${event.at.minute.toString().padLeft(2, '0')}';
    final icon = switch (event.type) {
      'snoozed' => Icons.snooze_rounded,
      'dismissed' => Icons.check_rounded,
      'emergency_dismissed' ||
      'emergency' ||
      'timed_out' => Icons.priority_high_rounded,
      _ => Icons.alarm_rounded,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: muted, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(event.label, style: const TextStyle(fontSize: 14)),
          ),
          const SizedBox(width: 10),
          Text(clock, style: const TextStyle(color: muted, fontSize: 13)),
        ],
      ),
    );
  }

  void _about() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ещё пять'),
      content: const Text(
        'Первая версия · 0.1.0\n\n'
        'Простой будильник, ограниченные переносы и задания для пробуждения.\n\n'
        'Без регистрации, рекламы и трекинга сна. Настройки и история остаются на телефоне.\n\n'
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

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: morning),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: Color(0xFFD5DDD1), fontSize: 11),
        ),
      ],
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
    this.color = morning,
  });
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(19),
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
              if (action != null)
                Padding(padding: const EdgeInsets.only(top: 6), child: action!),
            ],
          ),
        ),
      ],
    ),
  );
}
