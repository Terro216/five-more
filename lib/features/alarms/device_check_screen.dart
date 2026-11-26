import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../l10n/strings.dart';
import '../../models/device_alarm_check.dart';
import '../../services/alarm_gateway.dart';
import '../../widgets/exact_slider.dart';
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
  int _delaySeconds = 20;
  bool _delayValid = true;
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
          : result.error ?? appStrings.couldntFinishTheTest;
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
          enabled
              ? context.strings.turnOnUninstallProtection
              : context.strings.turnOffUninstallProtection,
        ),
        content: Text(
          enabled
              ? context.strings.uninstallProtectionConsent
              : context.strings.uninstallProtectionRemovalNotice,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('device-admin-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              enabled
                  ? context.strings.openAndroidPrompt
                  : context.strings.turnOffProtection,
            ),
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
        title: Text(context.strings.closeThePowerMenu),
        content: Text(context.strings.powerMenuConsent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('power-menu-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.openAndroidSettings),
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
            SnackBar(content: Text(appStrings.uninstallProtectionStillActive)),
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
          title: Text(context.strings.phoneCheck),
          actions: [
            IconButton(
              tooltip: context.strings.refreshStatus,
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
                      style: TextStyle(color: context.palette.red, height: 1.5),
                    ),
                  ),
                if (device.recoveryError != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      context.strings.scheduleRecoveryDetails(
                        device.recoveryError ?? '',
                      ),
                      key: const ValueKey('alarm-recovery-error'),
                      style: TextStyle(color: context.palette.red, height: 1.5),
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
                              successMessage:
                                  context.strings.restoredTestPrompt,
                            ),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(context.strings.tryRestoringAgain),
                    ),
                  const SizedBox(height: 20),
                ],
                if (!device.supported)
                  ..._preview()
                else ...[
                  Text(
                    context.strings.testYourAlarm,
                    style: AppTypography.heading,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.strings.startTheTestThenLockYourScreen,
                    style: TextStyle(color: context.palette.muted, height: 1.5),
                  ),
                  if (check?.pending == true) ...[
                    const SizedBox(height: 24),
                    ..._pendingCheck(check!, blocked),
                  ],
                  const SizedBox(height: 28),
                  _heading(context.strings.permissions),
                  if (device.platform == 'ios')
                    _permissionRow(
                      title: context.strings.alarmsOnIphoneLabel,
                      description: context.strings.allowSystemAlarmsToRing,
                      enabled: device.exactAlarms && device.notifications,
                      target: 'exactAlarms',
                      blocked: blocked,
                    )
                  else ...[
                    _permissionRow(
                      title: context.strings.notifications,
                      description: context.strings.notificationPermissionHint,
                      enabled: device.notifications,
                      target: 'notifications',
                      blocked: blocked,
                    ),
                    _permissionRow(
                      title: context.strings.exactAlarms,
                      description: context.strings.exactAlarmPermissionHint,
                      enabled: device.exactAlarms,
                      target: 'exactAlarms',
                      blocked: blocked,
                    ),
                    _permissionRow(
                      title: context.strings.lockScreenAccess,
                      description: context.strings.lockScreenPermissionHint,
                      enabled: device.fullScreenIntent,
                      target: 'fullScreenIntent',
                      blocked: blocked,
                    ),
                  ],
                  if (!device.notifications ||
                      !device.exactAlarms ||
                      !device.fullScreenIntent)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        context.strings.previousTestPermissionsChanged,
                        style: TextStyle(
                          color: context.palette.morning,
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (device.alarmVolume != null &&
                      device.alarmMaxVolume != null)
                    _advice(
                      icon: Icons.volume_up_outlined,
                      title: context.strings.alarmVolumeOf(
                        device.alarmVolume!,
                        device.alarmMaxVolume!,
                      ),
                      text: device.alarmVolume == 0
                          ? context.strings.mutedAlarmTestHint
                          : context.strings.audibleVolumeHint,
                      action: context.strings.adjustVolume,
                      onPressed: blocked
                          ? null
                          : () => _permission('alarmVolume'),
                    ),
                  if (device.platform == 'android')
                    _reliabilitySettings(device, blocked),
                  if (check?.pending != true) ...[
                    const SizedBox(height: 28),
                    _heading(context.strings.testAlarm),
                    if (check != null) ...[
                      _checkResult(check),
                      const SizedBox(height: 20),
                    ],
                    if (selected == null) ...[
                      Text(
                        context.strings.saveAlarmForTestHint,
                        style: TextStyle(
                          color: context.palette.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: blocked || !controller.storageHealthy
                            ? null
                            : _createAlarm,
                        icon: const Icon(Icons.add_rounded),
                        label: Text(context.strings.createAlarm),
                      ),
                    ] else ...[
                      DropdownButtonFormField<String>(
                        initialValue: selected.id,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.strings.alarmToTest,
                        ),
                        items: alarms
                            .map(
                              (alarm) => DropdownMenuItem(
                                value: alarm.id,
                                child: Text(
                                  [
                                    alarm.timeLabel,
                                    if (alarm.displayTitle.isNotEmpty)
                                      alarm.displayTitle,
                                  ].join(' · '),
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
                      Text(
                        context.strings.lockPhoneForTestHint,
                        style: TextStyle(
                          color: context.palette.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 18),
                      ExactSlider(
                        label: context.strings.ringAfter,
                        unit: context.strings.s,
                        value: _delaySeconds,
                        min: 1,
                        max: 60,
                        enabled: !blocked,
                        onValidityChanged: (v) =>
                            setState(() => _delayValid = v),
                        onChanged: (v) => setState(() => _delaySeconds = v),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('device-check-start'),
                        onPressed:
                            blocked ||
                                !_delayValid ||
                                !device.canSchedule ||
                                !controller.storageHealthy
                            ? null
                            : () => _run(
                                () => controller.startDeviceCheck(
                                  selected.id,
                                  delaySeconds: _delaySeconds,
                                ),
                              ),
                        icon: const Icon(Icons.phonelink_ring_rounded),
                        label: Text(
                          context.strings.testInSeconds(_delaySeconds),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (!device.canSchedule)
                        Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Text(
                            context.strings.allowNotificationsAndAlarmsFirst,
                            style: TextStyle(
                              color: context.palette.morning,
                              height: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ],
                  const SizedBox(height: 24),
                  if (!device.challengeEnforced)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        context.strings.iosTestStopHint,
                        style: TextStyle(
                          color: context.palette.muted,
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

  Widget _reliabilitySettings(AlarmDeviceStatus device, bool blocked) =>
      ExpansionTile(
        key: const ValueKey('device-reliability'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 16),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(appStrings.reliabilityAndProtection),
        subtitle: Text(appStrings.restartAndSystemSettings),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                appStrings.afterARestart,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                device.bootRecoverySupported == true
                    ? appStrings.androidRestartRecoveryDescription
                    : appStrings.recoverySupportUnknown,
                style: TextStyle(color: context.palette.muted, height: 1.5),
              ),
              if (device.powerMenuGuardActive != null) ...[
                const SizedBox(height: 20),
                Text(
                  appStrings.powerMenu,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  device.powerMenuGuardActive == true
                      ? appStrings.powerMenuProtectionActive
                      : appStrings.powerMenuPermissionHint,
                  key: const ValueKey('power-menu-status'),
                  style: TextStyle(color: context.palette.muted, height: 1.5),
                ),
                TextButton(
                  key: const ValueKey('power-menu-change'),
                  onPressed: blocked ? null : _changePowerMenuGuard,
                  child: Text(
                    device.powerMenuGuardActive == true
                        ? appStrings.turnOffPowerMenuProtection
                        : appStrings.turnOnPowerMenuProtection,
                  ),
                ),
              ],
              _advice(
                icon: Icons.battery_saver_outlined,
                title: switch (device.batteryOptimized) {
                  true => appStrings.batteryOptimizationIsRestrictingTheApp,
                  false => appStrings.batteryOptimizationExemptionIsOn,
                  null => appStrings.checkBatteryRestrictions,
                },
                text: appStrings.batteryExemptionHint,
                action: device.batteryOptimized == true
                    ? appStrings.allowUnrestrictedBatteryUse
                    : appStrings.openBatterySettings,
                onPressed: blocked ? null : () => _permission('battery'),
              ),
              TextButton(
                key: const ValueKey('device-app-settings'),
                onPressed: blocked ? null : () => _permission('appSettings'),
                child: Text(appStrings.appSettingsAndAutoStart),
              ),
              const SizedBox(height: 20),
              Text(
                appStrings.uninstallProtection,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                switch (device.deviceAdminActive) {
                  true => appStrings.deviceAdminEnabledHint,
                  false => appStrings.uninstallProtectionHint,
                  null => appStrings.deviceAdminUnavailableHint,
                },
                key: const ValueKey('device-admin-status'),
                style: TextStyle(color: context.palette.muted, height: 1.5),
              ),
              if (device.deviceAdminActive != null)
                TextButton(
                  key: const ValueKey('device-admin-change'),
                  onPressed: blocked || _adminRemoving
                      ? null
                      : () => _changeAdmin(device.deviceAdminActive != true),
                  child: Text(
                    device.deviceAdminActive == true
                        ? appStrings.turnOffUninstallProtectionLabel
                        : appStrings.turnOnUninstallProtectionLabel,
                  ),
                ),
              if (_adminRemoving)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    appStrings.androidIsTurningOffProtection,
                    key: ValueKey('device-admin-removing'),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                appStrings.androidRecoveryLimitations,
                style: TextStyle(color: context.palette.muted, height: 1.5),
              ),
              if (device.bootRecoverySupported == true &&
                  device.recoveryError == null)
                TextButton.icon(
                  key: const ValueKey('alarm-recovery-manual'),
                  onPressed: blocked
                      ? null
                      : () => _run(
                          controller.restoreAlarms,
                          successMessage: appStrings.restoredTestPrompt,
                        ),
                  icon: const Icon(Icons.restore_rounded),
                  label: Text(appStrings.restoreSchedule),
                ),
            ],
          ),
        ],
      );

  List<Widget> _preview() => [
    Icon(Icons.visibility_outlined, color: context.palette.morning, size: 48),
    const SizedBox(height: 24),
    Text(appStrings.exploreFiveMore, style: AppTypography.heading),
    const SizedBox(height: 12),
    Text(
      controller.device.error ?? appStrings.previewPlatformDescription,
      style: TextStyle(color: context.palette.muted, height: 1.5),
    ),
    const SizedBox(height: 24),
    FilledButton.icon(
      onPressed: _practice,
      icon: const Icon(Icons.extension_outlined),
      label: Text(appStrings.tryChallenge),
    ),
    const SizedBox(height: 12),
    OutlinedButton(
      onPressed: controller.busy || !controller.storageHealthy
          ? null
          : _createAlarm,
      child: Text(appStrings.createADraft),
    ),
  ];

  List<Widget> _pendingCheck(DeviceAlarmCheck check, bool blocked) {
    final seconds =
        (check.dueAt.difference(controller.now).inMilliseconds / 1000).ceil();
    final due = seconds <= 0;
    return [
      Text(
        due ? appStrings.didYouHearTheAlarm : appStrings.lockYourPhoneNow,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      if (!due) ...[
        Text(
          appStrings.ringsInS(seconds),
          key: const ValueKey('device-check-countdown'),
          style: TextStyle(
            color: context.palette.morning,
            fontSize: 28,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
      ],
      Text(
        due
            ? appStrings.reportAudibilityHint
            : appStrings.waitingForTestAlarmHint,
        style: TextStyle(color: context.palette.muted, height: 1.5),
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
          child: Text(appStrings.yesIHeardIt),
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
          child: Text(appStrings.iDidntHearIt),
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
        child: Text(appStrings.cancelTest),
      ),
    ];
  }

  Widget _checkResult(DeviceAlarmCheck check) {
    final date = check.confirmedAt;
    final when = date == null ? '' : ' · ${appDateTime(date)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          check.heard == true
              ? appStrings.reportedHeardOn(when)
              : appStrings.reportedSilentOn(when),
          style: const TextStyle(fontWeight: FontWeight.w700, height: 1.5),
        ),
        const SizedBox(height: 6),
        Text(
          check.heard == true
              ? appStrings.runTheTestAgainIfYouChange
              : appStrings.failedSoundTestAdvice,
          style: TextStyle(color: context.palette.muted, height: 1.5),
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
            color: enabled ? context.palette.muted : context.palette.morning,
            size: 22,
            semanticLabel: enabled ? appStrings.allowed : appStrings.off,
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
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              if (!enabled)
                TextButton(
                  onPressed: blocked ? null : () => _permission(target),
                  child: Text(
                    appStrings.allow(title.toLowerCase()),
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
            Icon(icon, color: context.palette.morning, size: 22),
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
        Text(text, style: TextStyle(color: context.palette.muted, height: 1.5)),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    ),
  );
}
