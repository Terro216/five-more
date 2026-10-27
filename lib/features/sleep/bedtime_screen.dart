import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../models/sleep_entry.dart';
import '../../services/native_extras.dart';
import '../../services/phrase_library.dart';
import '../../services/sleep_journal.dart';
import '../../widgets/time_composer.dart';

class BedtimeScreen extends StatefulWidget {
  const BedtimeScreen({super.key, required this.journal});
  final SleepJournal journal;
  @override
  State<BedtimeScreen> createState() => _BedtimeScreenState();
}

class _BedtimeScreenState extends State<BedtimeScreen>
    with WidgetsBindingObserver {
  bool _recording = false, _busy = false, _fetching = false;
  int _seconds = 0;
  Timer? _timer, _playbackTimer;
  String? _error;
  String? _playing;
  SleepJournal get journal => widget.journal;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPhrases());
  }

  Future<void> _loadPhrases() async {
    try {
      await PhraseLibrary.instance.load();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _recording) unawaited(_stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _playbackTimer?.cancel();
    if (_recording) unawaited(_saveOnClose());
    unawaited(_stopPlayback());
    super.dispose();
  }

  Future<void> _stopPlayback() async {
    _playbackTimer?.cancel();
    try {
      await NativeExtras.call<void>('stopAudio');
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is PlatformException
              ? e.message
              : 'Не удалось сохранить. Попробуй ещё раз.',
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _start() => _run(() async {
    await NativeExtras.call<void>('startRecording');
    if (!mounted) {
      await _saveOnClose();
      return;
    }
    _playbackTimer?.cancel();
    setState(() {
      _recording = true;
      _seconds = 0;
      _playing = null;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds >= 30) unawaited(_stop());
    });
  });
  Future<void> _saveRecording() async {
    final raw = await NativeExtras.call<Map>('stopRecording');
    if (raw != null) {
      await journal.addNote(
        VoiceNote(
          file: raw['file'] as String,
          at: DateTime.now(),
          seconds: (raw['seconds'] as num).round(),
        ),
      );
    }
  }

  Future<void> _saveOnClose() async {
    try {
      await _saveRecording();
    } catch (_) {
      // A completed native recording is recovered from disk on the next load.
    }
  }

  Future<void> _stop() async {
    if (!_recording || _busy) return;
    _timer?.cancel();
    setState(() => _recording = false);
    await _run(_saveRecording);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: journal,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        const Text(
          'Голос из утра',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          'Утром запиши, как тебе вставалось. Вечером послушай свой сонный голос — и вспомни, зачем сегодня лечь пораньше.',
          style: TextStyle(color: muted, height: 1.5),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const ValueKey('record-morning-note'),
          onPressed: _busy || !journal.ready
              ? null
              : _recording
              ? _stop
              : _start,
          icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(
            _recording
                ? 'Сохранить · $_seconds / 30 сек'
                : 'Записать до 30 секунд',
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Можно записать до звонка или после подъёма. Записи остаются на телефоне.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 24),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Напомнить, что пора спать'),
          subtitle: const Text('Уведомление откроет твои утренние записи'),
          value: journal.reminder,
          onChanged: _busy || !journal.ready
              ? null
              : (value) => _run(
                  () => journal.configureReminder(
                    value,
                    journal.bedHour,
                    journal.bedMinute,
                  ),
                ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bedtime_outlined, color: morning),
          title: Text(
            'Хочу ложиться в ${clockLabel(TimeOfDay(hour: journal.bedHour, minute: journal.bedMinute))}',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: _busy
              ? null
              : () async {
                  final picked = await editClock(
                    context,
                    TimeOfDay(hour: journal.bedHour, minute: journal.bedMinute),
                    title: 'Время отхода ко сну',
                  );
                  if (picked != null && mounted) {
                    await _run(
                      () => journal.configureReminder(
                        journal.reminder,
                        picked.hour,
                        picked.minute,
                      ),
                    );
                  }
                },
        ),
        if (_error != null || journal.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error ?? journal.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 24),
        Text(
          'Утренние записи · ${journal.notes.length}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (journal.notes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Первое послание появится здесь после записи.',
              style: TextStyle(color: muted),
            ),
          ),
        ...journal.notes.reversed.map(
          (note) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: IconButton(
              tooltip: _playing == note.file
                  ? 'Остановить запись'
                  : 'Послушать запись',
              icon: Icon(
                _playing == note.file
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
              ),
              onPressed: _busy || _recording
                  ? null
                  : () => _run(() async {
                      if (_playing == note.file) {
                        await _stopPlayback();
                        _playing = null;
                      } else {
                        await NativeExtras.call<void>('playNote', {
                          'file': note.file,
                        });
                        _playing = note.file;
                        _playbackTimer?.cancel();
                        _playbackTimer = Timer(
                          Duration(seconds: note.seconds + 1),
                          () {
                            if (mounted) setState(() => _playing = null);
                          },
                        );
                      }
                    }),
            ),
            title: Text(
              '${note.at.day}.${note.at.month.toString().padLeft(2, '0')} · ${clockLabel(TimeOfDay.fromDateTime(note.at))}',
            ),
            subtitle: Text('${note.seconds} сек'),
            trailing: IconButton(
              tooltip: 'Удалить запись',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _busy
                  ? null
                  : () async {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Удалить запись?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Оставить'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Удалить'),
                            ),
                          ],
                        ),
                      );
                      if (remove == true && mounted) {
                        await _run(() => journal.removeNote(note));
                      }
                    },
            ),
          ),
        ),
        const SizedBox(height: 28),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Фразы для зеркального текста'),
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Загружать новые фразы'),
              subtitle: const Text(
                'Forismatic · русский язык. Только запросы фраз; записи и дневник не отправляются.',
              ),
              value: PhraseLibrary.instance.enabled,
              onChanged: _busy
                  ? null
                  : (v) => _run(() => PhraseLibrary.instance.setEnabled(v)),
            ),
            const Text(
              'Обновляй запас здесь перед сном, не чаще раза в сутки. Во время звонка используются сохранённые и встроенные фразы; повтор — только после исчерпания набора.',
              style: TextStyle(color: muted, height: 1.5),
            ),
            TextButton.icon(
              onPressed: !PhraseLibrary.instance.enabled || _fetching
                  ? null
                  : () async {
                      setState(() => _fetching = true);
                      try {
                        final count = await PhraseLibrary.instance.refresh();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                count == 0
                                    ? 'Запас уже обновлён сегодня'
                                    : 'В запасе $count фраз',
                              ),
                            ),
                          );
                        }
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => _error = 'Источник фраз не ответил. Сохранённые и встроенные фразы доступны.',
                          );
                        }
                      }
                      if (mounted) setState(() => _fetching = false);
                    },
              icon: const Icon(Icons.download_rounded),
              label: Text(_fetching ? 'Загружаем…' : 'Обновить запас фраз'),
            ),
          ],
        ),
      ],
    ),
  );
}
