import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../models/device_alarm_check.dart';
import '../../services/alarm_gateway.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import 'alarm_editor.dart';

/// A device check records what the person heard, never inferred success from
/// receiving an event while the app happened to be in the foreground.
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({
    super.key,
    required this.controller,
    this.sourceAlarmId,
  });

  final AlarmController controller;
  final String? sourceAlarmId;

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  late final Timer _clock;
  final _scroll = ScrollController();
  String? _sourceAlarmId;
  String? _error;
  bool _acting = false;

  AlarmController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _sourceAlarmId = widget.sourceAlarmId;
    unawaited(controller.refreshStatus());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && controller.deviceCheck?.pending == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<AlarmResult> Function() action) async {
    if (_acting) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    final wasPending = controller.deviceCheck?.pending == true;
    final result = await action();
    if (!mounted) return;
    setState(() {
      _acting = false;
      _error = result.ok
          ? null
          : result.error ?? 'Не удалось завершить проверку.';
    });
    if (_error != null ||
        (!wasPending && controller.deviceCheck?.pending == true)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Future<void> _permission(String target) async {
    if (_acting) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    await controller.requestPermissions(target: target);
    if (!mounted) return;
    setState(() {
      _acting = false;
      _error = controller.error;
    });
  }

  Future<void> _createAlarm() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AlarmEditor(controller: controller)),
    );
    if (mounted) setState(() {});
  }

  void _practice() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => ChallengeScreen(
          kind: ChallengeKind.math,
          difficulty: ChallengeDifficulty.medium,
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
    builder: (context, _) {
      final device = controller.device;
      final check = controller.deviceCheck;
      final selectedId = check?.pending == true
          ? check!.sourceAlarmId
          : _sourceAlarmId;
      final alarms = controller.alarms;
      final selected =
          alarms.where((alarm) => alarm.id == selectedId).firstOrNull ??
          alarms.firstOrNull;
      final blocked = _acting || controller.busy;
      final displayError = _error ?? controller.error ?? device.error;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Проверка телефона'),
          actions: [
            IconButton(
              tooltip: 'Обновить статус',
              onPressed: blocked ? null : controller.refreshStatus,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                if (displayError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      displayError,
                      style: const TextStyle(
                        color: Color(0xFFFFB4AB),
                        height: 1.5,
                      ),
                    ),
                  ),
                if (!device.supported)
                  ..._preview()
                else ...[
                  const Text(
                    'Услышимся через 20 секунд',
                    style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Разрешения — первый шаг. Затем проверим настоящий звонок '
                    'с заблокированным экраном, как утром.',
                    style: TextStyle(color: muted, height: 1.5),
                  ),
                  if (check?.pending == true) ...[
                    const SizedBox(height: 24),
                    ..._pendingCheck(check!, blocked),
                  ],
                  const SizedBox(height: 28),
                  _heading('Разрешения'),
                  if (device.platform == 'ios')
                    _permissionRow(
                      title: 'Будильники на iPhone',
                      description: 'Разрешение на системный звонок.',
                      enabled: device.exactAlarms && device.notifications,
                      target: 'exactAlarms',
                      blocked: blocked,
                    )
                  else ...[
                    _permissionRow(
                      title: 'Уведомления',
                      description: 'Показывать будильник и управление им.',
                      enabled: device.notifications,
                      target: 'notifications',
                      blocked: blocked,
                    ),
                    _permissionRow(
                      title: 'Точное срабатывание',
                      description: 'Назначать звонок на выбранное время.',
                      enabled: device.exactAlarms,
                      target: 'exactAlarms',
                      blocked: blocked,
                    ),
                    _permissionRow(
                      title: 'Экран поверх блокировки',
                      description: 'Открывать экран подъёма при звонке.',
                      enabled: device.fullScreenIntent,
                      target: 'fullScreenIntent',
                      blocked: blocked,
                    ),
                  ],
                  if (!device.notifications ||
                      !device.exactAlarms ||
                      !device.fullScreenIntent)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Часть разрешений сейчас выключена. Прошлая проверка '
                        'не подтверждает работу с новыми настройками.',
                        style: TextStyle(color: morning, height: 1.5),
                      ),
                    ),
                  if (device.alarmVolume != null &&
                      device.alarmMaxVolume != null)
                    _advice(
                      icon: Icons.volume_up_outlined,
                      title:
                          'Громкость будильника: ${device.alarmVolume} из ${device.alarmMaxVolume}',
                      text: device.alarmVolume == 0
                          ? 'Сейчас звук выключен. Подними громкость перед проверкой.'
                          : 'Выбери громкость, которую слышно с кровати.',
                      action: 'Настроить громкость',
                      onPressed: blocked
                          ? null
                          : () => _permission('alarmVolume'),
                    ),
                  if (device.batteryOptimized == true)
                    _advice(
                      icon: Icons.battery_saver_outlined,
                      title: 'Включена экономия батареи для приложения',
                      text:
                          'Если звонок пропадёт при блокировке, проверь ограничения '
                          'батареи для «Ещё пять» в настройках телефона.',
                      action: 'Открыть настройки батареи',
                      onPressed: blocked ? null : () => _permission('battery'),
                    ),
                  if (check?.pending != true) ...[
                    const SizedBox(height: 28),
                    _heading('Проверочный звонок'),
                    if (check != null) ...[
                      _checkResult(check),
                      const SizedBox(height: 20),
                    ],
                    if (selected == null) ...[
                      const Text(
                        'Сначала сохрани будильник. Для проверки возьмём его '
                        'задание и настройки переносов.',
                        style: TextStyle(color: muted, height: 1.5),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: blocked || !controller.storageHealthy
                            ? null
                            : _createAlarm,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Создать будильник'),
                      ),
                    ] else ...[
                      DropdownButtonFormField<String>(
                        initialValue: selected.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Настройки для проверки',
                        ),
                        items: alarms
                            .map(
                              (alarm) => DropdownMenuItem(
                                value: alarm.id,
                                child: Text(
                                  '${alarm.timeLabel} · ${alarm.displayTitle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: blocked
                            ? null
                            : (value) => setState(() => _sourceAlarmId = value),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Основное расписание сохранится. После запуска заблокируй '
                        'телефон и оставь его рядом. Проверочный звонок нужно будет отключить.',
                        style: TextStyle(color: muted, height: 1.5),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        key: const ValueKey('device-check-start'),
                        onPressed:
                            blocked ||
                                !device.canSchedule ||
                                !controller.storageHealthy
                            ? null
                            : () => _run(
                                () => controller.startDeviceCheck(selected.id),
                              ),
                        icon: const Icon(Icons.phonelink_ring_rounded),
                        label: const Text(
                          'Проверить через 20 секунд',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (!device.canSchedule)
                        const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Text(
                            'Сначала включи разрешения на уведомления и будильники.',
                            style: TextStyle(color: morning, height: 1.5),
                          ),
                        ),
                    ],
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    'Результат отмечаешь ты. Даже успешная проверка не гарантирует '
                    'будущие звонки после изменения настроек телефона.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.5),
                  ),
                  if (!device.challengeEnforced)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'На iPhone системная кнопка остановки отключает звонок без задания. '
                        'Для задания открой приложение.',
                        style: TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  List<Widget> _preview() => [
    const Icon(Icons.visibility_outlined, color: morning, size: 48),
    const SizedBox(height: 24),
    const Text(
      'Знакомство с «Ещё пять»',
      style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 12),
    Text(
      controller.device.error ??
          'На этой платформе настоящий будильник недоступен. '
              'Можно сохранить настройки черновика и попробовать задания без звука.',
      style: const TextStyle(color: muted, height: 1.5),
    ),
    const SizedBox(height: 24),
    FilledButton.icon(
      onPressed: _practice,
      icon: const Icon(Icons.extension_outlined),
      label: const Text('Попробовать задание'),
    ),
    const SizedBox(height: 12),
    OutlinedButton(
      onPressed: controller.busy || !controller.storageHealthy
          ? null
          : _createAlarm,
      child: const Text('Настроить черновик'),
    ),
  ];

  List<Widget> _pendingCheck(DeviceAlarmCheck check, bool blocked) {
    final seconds =
        (check.dueAt.difference(controller.now).inMilliseconds / 1000).ceil();
    final due = seconds <= 0;
    return [
      Text(
        due ? 'Прозвучал ли будильник?' : 'Заблокируй телефон сейчас',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      if (!due) ...[
        Text(
          'До звонка: $seconds сек',
          key: const ValueKey('device-check-countdown'),
          style: const TextStyle(
            color: morning,
            fontSize: 28,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
      ],
      Text(
        due
            ? 'Если звук был слышен с заблокированным экраном, отметь это. '
                  'Мы не можем проверить звук за тебя. Ответ остановит проверочный звонок, если он ещё звучит.'
            : 'Оставь телефон рядом и дождись звука. Затем открой приложение '
                  'и отметь результат. Проверка сохранится, даже если закрыть этот экран.',
        style: const TextStyle(color: muted, height: 1.5),
      ),
      const SizedBox(height: 18),
      if (due) ...[
        FilledButton(
          key: const ValueKey('device-check-heard'),
          onPressed: blocked
              ? null
              : () => _run(
                  () => controller.finishDeviceCheck(
                    heard: true,
                    previewAlarmId: check.previewAlarmId,
                  ),
                ),
          child: const Text('Да, зазвонил'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          key: const ValueKey('device-check-not-heard'),
          onPressed: blocked
              ? null
              : () => _run(
                  () => controller.finishDeviceCheck(
                    heard: false,
                    previewAlarmId: check.previewAlarmId,
                  ),
                ),
          child: const Text('Не зазвонил'),
        ),
        const SizedBox(height: 10),
      ],
      TextButton(
        key: const ValueKey('device-check-cancel'),
        onPressed: blocked
            ? null
            : () => _run(
                () => controller.cancelDeviceCheck(
                  previewAlarmId: check.previewAlarmId,
                ),
              ),
        child: const Text('Отменить проверку'),
      ),
    ];
  }

  Widget _checkResult(DeviceAlarmCheck check) {
    final date = check.confirmedAt;
    final when = date == null
        ? ''
        : ' · ${date.day}.${date.month.toString().padLeft(2, '0')} '
              '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          check.heard == true
              ? 'Ты подтвердил: звук был$when'
              : 'Ты отметил: звука не было$when',
          style: const TextStyle(fontWeight: FontWeight.w700, height: 1.5),
        ),
        const SizedBox(height: 6),
        Text(
          check.heard == true
              ? 'Повтори проверку, если поменяешь настройки телефона.'
              : 'Проверь громкость будильника, разрешения и ограничения батареи. '
                    'Затем повтори проверку с заблокированным экраном.',
          style: const TextStyle(color: muted, height: 1.5),
        ),
      ],
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );

  Widget _permissionRow({
    required String title,
    required String description,
    required bool enabled,
    required String target,
    required bool blocked,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            enabled
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            color: enabled ? muted : morning,
            size: 22,
            semanticLabel: enabled ? 'Разрешено' : 'Выключено',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(color: muted, fontSize: 13, height: 1.4),
              ),
              if (!enabled)
                TextButton(
                  onPressed: blocked ? null : () => _permission(target),
                  child: Text(
                    'Разрешить: ${title.toLowerCase()}',
                    textAlign: TextAlign.start,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _advice({
    required IconData icon,
    required String title,
    required String text,
    required String action,
    required VoidCallback? onPressed,
  }) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: morning, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(text, style: const TextStyle(color: muted, height: 1.5)),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    ),
  );
}
