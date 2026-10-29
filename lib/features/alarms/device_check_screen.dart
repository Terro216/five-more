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
  Timer? _adminTimer;
  bool _adminRemoving = false;
  bool _adminPollBusy = false;

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
    _adminTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<AlarmResult> Function() action, {
    String? successMessage,
  }) async {
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
    if (result.ok && successMessage != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successMessage)));
    }
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
    if (_error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  Future<void> _createAlarm() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AlarmEditor(controller: controller)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _changeAdmin(bool enabled) async {
    if (_acting || _adminRemoving || controller.busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          enabled ? 'Защитить от удаления?' : 'Снять защиту от удаления?',
        ),
        content: Text(
          enabled
              ? 'Android предложит сделать «Ещё пять» администратором устройства. '
                    'Перед удалением приложения потребуется снять этот статус. '
                    'Это дополнительный шаг против удаления в полусне. '
                    'Защиту можно отключить здесь или в системных настройках. '
                    'Приложение не получает права стирать данные или менять пароль телефона.'
              : 'Приложение можно будет удалить обычным способом. '
                    'Будильники и их настройки сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('device-admin-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(enabled ? 'Открыть запрос Android' : 'Снять защиту'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _permission(enabled ? 'deviceAdmin' : 'removeDeviceAdmin');
      if (!enabled &&
          mounted &&
          controller.error == null &&
          controller.device.deviceAdminActive == true) {
        _watchAdminRemoval();
      }
    }
  }

  Future<void> _changePowerMenuGuard() async {
    if (_acting || controller.busy) return;
    if (controller.device.powerMenuGuardActive == true) {
      await _permission('removePowerMenuGuard');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Закрывать меню питания?'),
        content: const Text(
          'Включи службу «Ещё пять — меню питания» в специальных возможностях Android. '
          'Она закрывает распознанное меню питания только во время настоящего звонка.\n\n'
          'Служба получает сведения о системных окнах. Содержимое приложений '
          'не читается, не сохраняется и не передаётся. Защиту можно отключить здесь '
          'или в настройках Android.\n\n'
          'Работает не на всех телефонах. Принудительную перезагрузку кнопками '
          'не блокирует; аварийный выход из будильника остаётся доступен.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('power-menu-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Открыть настройки Android'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _permission('powerMenuGuard');
  }

  void _watchAdminRemoval() {
    _adminTimer?.cancel();
    setState(() => _adminRemoving = true);
    var attempts = 0;
    _adminTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) async {
      if (_adminPollBusy || !mounted) return;
      _adminPollBusy = true;
      attempts += 1;
      await controller.refreshStatus();
      _adminPollBusy = false;
      if (!mounted) return;
      if (controller.device.deviceAdminActive != true || attempts >= 8) {
        timer.cancel();
        setState(() => _adminRemoving = false);
        if (controller.device.deviceAdminActive == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Android пока сообщает, что защита включена. Обнови статус или сними её в системных настройках.',
              ),
            ),
          );
        }
      }
    });
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
      final actionError = _error ?? controller.error ?? device.error;
      final displayError = actionError == device.recoveryError
          ? null
          : actionError;
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
                if (device.recoveryError != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      'Расписание восстановлено не полностью. ${device.recoveryError}',
                      key: const ValueKey('alarm-recovery-error'),
                      style: const TextStyle(
                        color: Color(0xFFFFB4AB),
                        height: 1.5,
                      ),
                    ),
                  ),
                  if (device.platform == 'android' &&
                      device.bootRecoverySupported == true)
                    TextButton.icon(
                      key: const ValueKey('alarm-recovery-retry'),
                      onPressed: blocked
                          ? null
                          : () => _run(
                              controller.restoreAlarms,
                              successMessage: 'Расписание восстановлено. Проверь звонок на телефоне.',
                            ),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Повторить восстановление'),
                    ),
                  const SizedBox(height: 20),
                ],
                if (!device.supported)
                  ..._preview()
                else ...[
                  const Text(
                    'Услышимся через 20 секунд',
                    style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Запусти тест и заблокируй экран.',
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
                  if (device.platform == 'android')
                    _reliabilitySettings(device, blocked),
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

  Widget _reliabilitySettings(
    AlarmDeviceStatus device,
    bool blocked,
  ) => ExpansionTile(
    key: const ValueKey('device-reliability'),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 16),
    shape: const Border(),
    collapsedShape: const Border(),
    title: const Text('Надёжность и защита'),
    subtitle: const Text('Перезагрузка и системные настройки'),
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'После перезагрузки',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            device.bootRecoverySupported == true
                ? 'Начавшийся подъём продолжается после загрузки Android без ограничения '
                      'по времени. Расписание и потраченные минуты переноса сохраняются. '
                      'Проверь восстановление звонка на своём телефоне.'
                : 'Поддержку восстановления на этом устройстве не удалось подтвердить. '
                      'Обнови статус и проверь звонок после перезагрузки.',
            style: const TextStyle(color: muted, height: 1.5),
          ),
          if (device.powerMenuGuardActive != null) ...[
            const SizedBox(height: 20),
            const Text(
              'Меню питания',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              device.powerMenuGuardActive == true
                  ? 'Защита включена. Во время звонка приложение закрывает распознанное меню питания. Проверь на своём телефоне.'
                  : 'Закрывать меню выключения во время звонка. Требуется отдельное разрешение Android; работает не на всех телефонах.',
              key: const ValueKey('power-menu-status'),
              style: const TextStyle(color: muted, height: 1.5),
            ),
            TextButton(
              key: const ValueKey('power-menu-change'),
              onPressed: blocked ? null : _changePowerMenuGuard,
              child: Text(
                device.powerMenuGuardActive == true
                    ? 'Выключить защиту меню'
                    : 'Включить защиту меню',
              ),
            ),
          ],
          _advice(
            icon: Icons.battery_saver_outlined,
            title: switch (device.batteryOptimized) {
              true => 'Приложение ограничено оптимизацией батареи',
              false => 'Исключение из оптимизации батареи включено',
              null => 'Проверь ограничения батареи',
            },
            text:
                'Исключение помогает будильнику работать в фоне. На некоторых '
                'телефонах нужно дополнительно разрешить автозапуск в настройках приложения.',
            action: device.batteryOptimized == true
                ? 'Разрешить работу без оптимизации'
                : 'Открыть настройки батареи',
            onPressed: blocked ? null : () => _permission('battery'),
          ),
          TextButton(
            key: const ValueKey('device-app-settings'),
            onPressed: blocked ? null : () => _permission('appSettings'),
            child: const Text('Настройки приложения и автозапуск'),
          ),
          const SizedBox(height: 20),
          const Text(
            'Защита от удаления',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            switch (device.deviceAdminActive) {
              true =>
                'Статус администратора включён. Для удаления приложения '
                    'сначала потребуется снять защиту. Её можно отключить здесь '
                    'или в системных настройках.',
              false =>
                'Дополнительный шаг против удаления приложения в полусне. '
                    'Включается отдельно через системный запрос Android.',
              null =>
                'Администратор устройства здесь недоступен. '
                    'Эта защита не требуется для обычного звонка.',
            },
            key: const ValueKey('device-admin-status'),
            style: const TextStyle(color: muted, height: 1.5),
          ),
          if (device.deviceAdminActive != null)
            TextButton(
              key: const ValueKey('device-admin-change'),
              onPressed: blocked || _adminRemoving
                  ? null
                  : () => _changeAdmin(device.deviceAdminActive != true),
              child: Text(
                device.deviceAdminActive == true
                    ? 'Снять защиту от удаления'
                    : 'Включить защиту от удаления',
              ),
            ),
          if (_adminRemoving)
            Semantics(
              liveRegion: true,
              child: const Text(
                'Android снимает защиту…',
                key: ValueKey('device-admin-removing'),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Принудительная перезагрузка кнопками и остановка через настройки Android остаются доступны. '
            'После принудительной остановки открой приложение и восстанови расписание. '
            'В режиме «Не беспокоить» разреши будильники в настройках звука телефона.',
            style: TextStyle(color: muted, height: 1.5),
          ),
          if (device.bootRecoverySupported == true &&
              device.recoveryError == null)
            TextButton.icon(
              key: const ValueKey('alarm-recovery-manual'),
              onPressed: blocked
                  ? null
                  : () => _run(
                      controller.restoreAlarms,
                      successMessage: 'Расписание восстановлено. Проверь звонок на телефоне.',
                    ),
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Восстановить расписание'),
            ),
        ],
      ),
    ],
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
