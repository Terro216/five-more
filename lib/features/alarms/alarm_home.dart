import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/alarm.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';
import 'device_check_screen.dart';

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
                  _ => _history(),
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
    final totalMinutes = (duration.inSeconds / 60).ceil();
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
        onTap: controller.busy ? null : () => _edit(alarm),
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
    final title = !device.supported
        ? 'Режим знакомства'
        : missingPermission
        ? 'Проверь разрешения телефона'
        : device.alarmVolume == 0
        ? 'Звук будильника выключен'
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
    child: Material(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: controller.busy ? null : () => _edit(alarm),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        alarm.timeLabel,
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -1,
                          color: alarm.enabled ? Colors.white : muted,
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
                      onChanged: controller.busy || !controller.device.supported
                          ? null
                          : (value) => _toggle(alarm, value),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: ValueKey('alarm-menu-${alarm.id}'),
                    tooltip: 'Действия с будильником',
                    enabled: !controller.busy,
                    onSelected: (action) {
                      if (action == 'edit') _edit(alarm);
                      if (action == 'test') _checkDevice(alarm);
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
          subtitle: Text(switch (kind) {
            ChallengeKind.math => 'Реши несколько примеров',
            ChallengeKind.memory => 'Повтори рисунок из клеток',
            ChallengeKind.stroop => 'Выбери цвет букв, не слово',
            ChallengeKind.sequence => 'Нажимай числа по порядку',
            ChallengeKind.mixed => 'Все четыре задания по очереди',
          }, style: const TextStyle(color: muted, fontSize: 13)),
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
        'Версия · 0.4.0\n\n'
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
