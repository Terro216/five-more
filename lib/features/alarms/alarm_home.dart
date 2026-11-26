import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../app/alarm_controller.dart';
import '../../app/theme.dart';
import '../../l10n/strings.dart';
import '../../models/alarm.dart';
import '../../models/sleep_session.dart';
import '../../services/appearance_settings.dart';
import '../../services/native_extras.dart';
import '../../services/sleep_journal.dart';
import '../../services/sync_service.dart';
import '../../widgets/time_composer.dart';
import '../challenges/challenge_models.dart';
import '../challenges/challenge_screen.dart';
import '../challenges/phrase_settings.dart';
import '../history/history_view.dart';
import '../sleep/bedtime_screen.dart';
import '../sleep/sleep_review.dart';
import '../sleep/sleep_reviews.dart';
import '../sync/sync_screen.dart';
import 'alarm_editor.dart';
import 'device_check_screen.dart';
import 'ringing_screen.dart';

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
    TimeOfDay? settingsTime;
    final time = await editClock(
      context,
      TimeOfDay(hour: alarm.hour, minute: alarm.minute),
      now: () => controller.now,
      onSettings: (time) => settingsTime = time,
      nextAt: (time) => alarm
          .copyWith(hour: time.hour, minute: time.minute, clearOneShotAt: true)
          .nextOccurrence(controller.now),
    );
    if (!mounted) return;
    if (settingsTime != null) {
      await _edit(alarm, settingsTime);
      return;
    }
    if (time == null) return;
    final result = await controller.saveAlarm(
      alarm.copyWith(
        enabled: true,
        hour: time.hour,
        minute: time.minute,
        clearOneShotAt: true,
      ),
    );
    if (mounted) {
      if (!result.ok) _message(result.error ?? appStrings.couldntChangeTheTime);
    }
  }

  Widget _reviewArchive() => TextButton.icon(
    onPressed: () => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SleepReviews(journal: _journal, controller: controller),
      ),
    ),
    icon: const Icon(Icons.history_rounded),
    label: Text(appStrings.sleepDiary),
  );

  Widget _morningReview() {
    final session = SleepSession.fromEvents(
      controller.sleepEvents,
      separateOccurrences: _journal.entries
          .where((e) => e.separate)
          .map((e) => e.occurrenceId)
          .toSet(),
    ).lastOrNull;
    final event = session?.lastEvent;
    if (!_journal.ready ||
        session == null ||
        event == null ||
        session.occurrences.any(_journal.reported) ||
        controller.now.difference(event.at) > const Duration(hours: 18)) {
      return _reviewArchive();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appStrings.howDidYouSleep,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          Text(
            appStrings.sleepReviewSummary(
              sleepDateLabel(event.at),
              clockLabel(TimeOfDay.fromDateTime(event.at)),
              session.occurrences.length > 1
                  ? appStrings.alarmCountSuffix(session.occurrences.length)
                  : '',
            ),
            style: TextStyle(color: context.palette.muted),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SleepReview(
                      journal: _journal,
                      controller: controller,
                      event: event,
                      session: session,
                    ),
                  ),
                ),
                child: Text(appStrings.rateYourMorning),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _tab = 2),
                icon: const Icon(Icons.mic_outlined),
                label: Text(appStrings.recordAMessage),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await _journal.skipAll(session.occurrences);
                  } catch (_) {
                    if (mounted) {
                      _message(appStrings.couldntSaveTryAgain);
                    }
                  }
                },
                child: Text(appStrings.skip),
              ),
              _reviewArchive(),
            ],
          ),
        ],
      ),
    );
  }

  int _tab = 0;
  ChallengeDifficulty _practiceDifficulty = ChallengeDifficulty.medium;
  AlarmController get controller => widget.controller;

  Future<void> _edit([Alarm? alarm, TimeOfDay? initialTime]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AlarmEditor(
          controller: controller,
          alarm: alarm,
          initialTime: initialTime,
        ),
      ),
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggle(Alarm alarm, bool value) async {
    final active = controller.activeOccurrence(alarm.id);
    if (!value && active != null) {
      await _openWake(active, disableAlarm: true);
      return;
    }
    final result = await controller.setEnabled(alarm, value);
    if (!result.ok && mounted) {
      _message(result.error ?? appStrings.couldntUpdateTheAlarmLabel);
    }
  }

  Future<void> _openWake(RingingAlarm active, {bool disableAlarm = false}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RingingScreen(
            controller: controller,
            ringing: active,
            allowBack: true,
            disableAlarm: disableAlarm,
          ),
        ),
      );

  Future<void> _delete(Alarm alarm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.deleteThisAlarm),
        content: Text('${alarm.timeLabel} · ${alarm.repeatLabel}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await controller.deleteAlarm(alarm.id);
    if (mounted) {
      _message(
        result.ok
            ? appStrings.alarmDeleted
            : result.error ?? appStrings.couldntDeleteTheAlarm,
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
        title: LayoutBuilder(
          builder: (context, constraints) {
            final showName =
                constraints.maxWidth >=
                42 + MediaQuery.textScalerOf(context).scale(110);
            return Row(
              children: [
                Tooltip(
                  message: context.strings.appName,
                  child: _SunMark(size: 30),
                ),
                if (showName) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.strings.appWordmark,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.8,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          IconButton(
            key: const ValueKey('toggle-theme'),
            tooltip: Theme.of(context).brightness == Brightness.dark
                ? context.strings.lightTheme
                : context.strings.darkTheme,
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
            onPressed: () async {
              try {
                await AppearanceSettings.instance.toggle();
              } catch (_) {
                if (mounted) {
                  _message(appStrings.themeSaveError);
                }
              }
            },
          ),
          IconButton(
            tooltip: context.strings.phoneCheck,
            onPressed: () => _checkDevice(),
            icon: const Icon(Icons.phonelink_ring_outlined),
          ),
          IconButton(
            tooltip: context.strings.syncLabel,
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SyncScreen(sync: SyncService.instance),
                ),
              );
              await _journal.load();
            },
          ),
          IconButton(
            tooltip: context.strings.about,
            onPressed: _about,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _tab == 0 && !controller.loading
          ? FloatingActionButton(
              key: const ValueKey('add-alarm'),
              tooltip: context.strings.addAlarm,
              onPressed: controller.storageHealthy ? () => _edit() : null,
              child: const Icon(Icons.add_rounded),
            )
          : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.alarm_outlined),
                selectedIcon: Icon(Icons.alarm_rounded),
                label: context.strings.alarmsTab,
              ),
              NavigationDestination(
                icon: Icon(Icons.extension_outlined),
                selectedIcon: Icon(Icons.extension_rounded),
                label: context.strings.challenges,
              ),
              NavigationDestination(
                icon: Icon(Icons.bedtime_outlined),
                selectedIcon: Icon(Icons.bedtime_rounded),
                label: context.strings.bedtimeTab,
              ),
              NavigationDestination(
                icon: Icon(Icons.history_rounded),
                label: context.strings.history,
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
                    archive: true,
                    events: controller.events,
                    journal: _journal,
                    now: controller.now,
                  ),
                },
              ),
            ),
    ),
  );

  List<Alarm> _sortedAlarms() {
    final alarms = controller.alarms;
    final order = {for (var i = 0; i < alarms.length; i++) alarms[i].id: i};
    return [...alarms]..sort((a, b) {
      final time = (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute);
      return time != 0 ? time : order[a.id]!.compareTo(order[b.id]!);
    });
  }

  Widget _today() {
    final now = controller.now;
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          Text(
            _dayTitle(now),
            style: TextStyle(color: context.palette.muted, fontSize: 13),
          ),
          const SizedBox(height: 14),
          for (final active in controller.snoozedAlarms.where(
            (a) => !a.alarm.id.startsWith('preview:'),
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ListTile(
                key: ValueKey('snoozed-${active.alarm.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.snooze_rounded),
                title: Text(
                  appStrings.alarmSnoozedUntil(
                    clockLabel(TimeOfDay.fromDateTime(active.snoozedUntil!)),
                  ),
                ),
                subtitle: Text(appStrings.openAndDismissAlarm),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _openWake(active),
              ),
            ),
          _HomeClock(
            builder: () {
              final current = controller.nextAlarm(controller.now);
              return current == null
                  ? _emptyCard()
                  : _nextCard(current, controller.now);
            },
          ),
          const SizedBox(height: 12),
          _deviceCard(),
          _morningReview(),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _InfoCard(
                icon: Icons.error_outline_rounded,
                title: appStrings.needsAttention,
                text: controller.error!,
                color: context.palette.red,
              ),
            ),
          if (todaySnoozes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _InfoCard(
                icon: Icons.snooze_rounded,
                title: appStrings.snoozesToday(todaySnoozes),
              ),
            ),
          if (controller.alarms.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    appStrings.myAlarms,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${controller.alarms.length}',
                  style: TextStyle(color: context.palette.muted),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...(_sortedAlarms()).map(_alarmCard),
          ],
          if (!controller.device.challengeEnforced)
            Padding(
              padding: EdgeInsets.only(top: 14),
              child: _InfoCard(
                icon: Icons.phone_iphone_rounded,
                title: appStrings.alarmsOnIphone,
                text: appStrings.iosSystemStopExplanation,
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
        ? appStrings.hoursMinutes(hours, minutes.toString().padLeft(2, '0'))
        : appStrings.minutesShort(minutes);
    final time = Text(
      appClock(nextAt.hour, nextAt.minute),
      style: TextStyle(
        fontSize: 56,
        fontWeight: FontWeight.w400,
        height: 1.1,
        letterSpacing: -1.5,
        color: context.palette.morning,
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
          appStrings.nextAlarmIn(left),
          style: TextStyle(color: context.palette.muted, fontSize: 13),
        ),
      ],
    );
    return Material(
      color: context.palette.panel,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const ValueKey('next-alarm'),
        onTap: controller.isAlarmBusy(alarm.id) ? null : () => _editTime(alarm),
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
              ? appStrings.setYourFirstAlarm
              : appStrings.noUpcomingAlarm,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: -.6,
          ),
        ),
        if (controller.alarms.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            appStrings.firstAlarmHint,
            style: TextStyle(
              color: context.palette.muted,
              height: 1.5,
              fontSize: 14,
            ),
          ),
        ],
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
        ? appStrings.previewMode
        : missingPermission
        ? appStrings.checkPhonePermissions
        : device.alarmVolume == 0
        ? appStrings.alarmVolumeIsOff
        : device.recoveryError != null
        ? appStrings.restoreYourAlarmSchedule
        : device.error != null
        ? appStrings.couldntCheckThisPhone
        : check?.pending == true
        ? appStrings.alarmTestStarted
        : check?.heard == true
        ? appStrings.youConfirmedYouHeardTheAlarm
        : check?.heard == false
        ? appStrings.youReportedTheAlarmWasSilent
        : appStrings.thisPhoneHasntBeenTested;
    final text = !device.supported
        ? appStrings.previewCapabilities
        : missingPermission
        ? appStrings.permissionsBeforeNextAlarm
        : device.alarmVolume == 0
        ? appStrings.turnUpTheAlarmVolumeAndRun
        : device.recoveryError != null
        ? appStrings.retryRecoveryHint
        : device.error != null
        ? device.error!
        : check?.pending == true
        ? appStrings.reportTestResultHint
        : check?.heard == true
        ? appStrings.retestAfterSettingsChange
        : check?.heard == false
        ? appStrings.silentAlarmAdvice
        : appStrings.testTheAlarmWithYourScreenLocked;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('home-device-check'),
        onTap: () => _checkDevice(),
        borderRadius: BorderRadius.circular(12),
        child: Semantics(
          button: true,
          label: device.supported
              ? appStrings.phoneCheck
              : appStrings.whatsAvailableHere,
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
                    color: context.palette.morning,
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
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: context.palette.muted),
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
      direction: controller.isAlarmBusy(alarm.id)
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
          CustomSemanticsAction(label: appStrings.deleteAlarm): () =>
              _delete(alarm),
        },
        child: Material(
          color: context.palette.panel,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: controller.isAlarmBusy(alarm.id) ? null : () => _edit(alarm),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (alarm.displayTitle.isNotEmpty)
                    Text(
                      alarm.displayTitle,
                      key: ValueKey('alarm-name-${alarm.id}'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (alarm.displayTitle.isNotEmpty) const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: InkWell(
                            key: ValueKey('alarm-time-${alarm.id}'),
                            onTap: controller.isAlarmBusy(alarm.id)
                                ? null
                                : () => _editTime(alarm),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                alarm.timeLabel,
                                style: TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.w400,
                                  color: alarm.enabled
                                      ? context.palette.foreground
                                      : context.palette.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        label: appStrings.toggleAlarmAt(
                          alarm.timeLabel,
                          alarm.enabled
                              ? appStrings.turnOff
                              : appStrings.turnOn,
                        ),
                        child: Switch(
                          key: ValueKey('alarm-toggle-${alarm.id}'),
                          value: alarm.enabled,
                          onChanged:
                              controller.isAlarmBusy(alarm.id) ||
                                  !controller.device.supported
                              ? null
                              : (value) => _toggle(alarm, value),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    alarm.repeatLabel,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Text(
                        alarm.requiresChallenge
                            ? '${alarm.challengeKind.label} · ${alarm.difficulty.label.toLowerCase()}'
                            : appStrings.standardAlarm,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        alarm.snoozeBudget == 0
                            ? appStrings.noSnoozes
                            : appStrings.minOfSnoozeTime(alarm.snoozeBudget),
                        style: TextStyle(
                          color: context.palette.morning,
                          fontSize: 12,
                        ),
                      ),
                      if (alarm.requiresChallenge &&
                          alarm.escalateOnSnooze &&
                          alarm.snoozeBudget > 0)
                        Text(
                          appStrings.harderAfterEachSnooze,
                          style: TextStyle(
                            color: context.palette.morning,
                            fontSize: 12,
                          ),
                        ),
                      if (!controller.device.supported)
                        Text(
                          appStrings.draft,
                          style: TextStyle(
                            color: context.palette.muted,
                            fontSize: 12,
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
  );

  Widget _challenges() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      Text(appStrings.wakeUpYourMind, style: AppTypography.heading),
      const SizedBox(height: 8),
      Text(
        appStrings.practiceDescription,
        style: TextStyle(
          color: context.palette.muted,
          height: 1.4,
          fontSize: 14,
        ),
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
      const PhraseSettings(),
      const SizedBox(height: 12),
      ...ChallengeKind.values.map(
        (kind) => ListTile(
          key: ValueKey('practice-kind-${kind.name}'),
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: 8,
          leading: Icon(challengeIcon(kind), color: context.palette.morning),
          title: Text(
            kind.label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            kind.description,
            style: TextStyle(color: context.palette.muted, fontSize: 13),
          ),
          trailing: ExcludeSemantics(
            child: Icon(
              Icons.play_arrow_rounded,
              color: context.palette.morning,
            ),
          ),
          onTap: () => _practice(kind),
        ),
      ),
      Padding(
        padding: EdgeInsets.only(top: 16),
        child: Text(
          appStrings.difficultyAndEmergencyHint,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    ],
  );

  Future<void> _about() async {
    final version = NativeExtras.version();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.appName),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<String>(
              future: version,
              builder: (context, snapshot) =>
                  Text(context.strings.aboutDescription(snapshot.data ?? '…')),
            ),
            const SizedBox(height: 16),
            _LanguageSetting(),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.strings.gotIt),
          ),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _relativeDay(DateTime date, DateTime now) {
  if (_sameDay(date, now)) return appStrings.today;
  if (_sameDay(date, DateTime(now.year, now.month, now.day + 1))) {
    return appStrings.tomorrow;
  }
  final weekdays = [
    appStrings.monday,
    appStrings.tuesday,
    appStrings.wednesday,
    appStrings.thursday,
    appStrings.friday,
    appStrings.saturday,
    appStrings.sunday,
  ];
  return weekdays[date.weekday - 1];
}

String _dayTitle(DateTime date) => appFullDate(date);

class _SunMark extends StatelessWidget {
  const _SunMark({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: context.palette.morning,
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(
      Icons.wb_twilight_rounded,
      color: context.palette.ink,
      size: size * .65,
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    this.text = '',
    this.color,
  });
  final IconData icon;
  final String title;
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: (color ?? context.palette.morning).withValues(alpha: .06),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: (color ?? context.palette.morning).withValues(alpha: .12),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color ?? context.palette.morning, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color ?? context.palette.morning,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (text.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  text,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _HomeClock extends StatefulWidget {
  const _HomeClock({required this.builder});
  final Widget Function() builder;
  @override
  State<_HomeClock> createState() => _HomeClockState();
}

class _HomeClockState extends State<_HomeClock> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder();
}

class _LanguageSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final language = AppLanguage.instance;
    Future<void> change(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.strings.languageSaveError)),
          );
        }
      }
    }

    if (language.usesIosSettings) {
      return TextButton.icon(
        icon: const Icon(Icons.language),
        label: Text(context.strings.appLanguage),
        onPressed: () => change(language.openIosSettings),
      );
    }
    return ValueListenableBuilder(
      valueListenable: language,
      builder: (context, selected, _) => DropdownButtonFormField<String>(
        key: ValueKey(selected),
        initialValue: selected?.languageCode ?? '',
        decoration: InputDecoration(labelText: context.strings.appLanguage),
        isExpanded: true,
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(context.strings.systemLanguage),
          ),
          const DropdownMenuItem(value: 'en', child: Text('English')),
          const DropdownMenuItem(value: 'ru', child: Text('Русский')),
        ],
        onChanged: (code) => change(
          () => language.select(
            code == null || code.isEmpty ? null : Locale(code),
          ),
        ),
      ),
    );
  }
}
