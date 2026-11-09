import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sleep_entry.dart';
import '../models/sleep_goals.dart';
import 'native_extras.dart';
import 'local_database.dart';

class SleepJournal extends ChangeNotifier {
  static const _key = 'five_more.sleep.v1';
  List<SleepEntry> entries = [];
  SleepGoals goals = const SleepGoals();
  Map<String, dynamic> sleepEstimates = {};
  // Local wall times keep historical regularity stable after travel. These
  // offsets are not added to the existing statistics-sync contract.
  Map<String, dynamic> sleepTimezones = {};
  Future<void> setGoals(SleepGoals value) async {
    final previous = goals;
    goals = value;
    try {
      await _persist();
    } catch (_) {
      goals = previous;
      rethrow;
    }
  }

  Future<void> saveEstimate(String id, Map<String, Object?> value) async {
    // Preserve the first proposal separately from later manual corrections.
    if (sleepEstimates.containsKey(id)) return;
    sleepEstimates[id] = value;
    try {
      await _persist();
    } catch (_) {
      sleepEstimates.remove(id);
      rethrow;
    }
  }

  List<VoiceNote> notes = [];
  Set<String> skipped = {};
  bool reminder = false;
  int bedHour = 23;
  int bedMinute = 0;
  int fallingAsleepMinutes = 20;
  bool ready = false;
  String? error;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final stored = usesSqlite
          ? await LocalDatabase.instance.setting('journal')
          : null;
      final raw = usesSqlite
          ? jsonEncode({
              ...?stored,
              'entries': await LocalDatabase.instance.records('sleep'),
              'notes': await LocalDatabase.instance.records('note'),
            })
          : (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        goals = SleepGoals.fromJson(
          Map<String, dynamic>.from(data['goals'] as Map? ?? {}),
        );
        sleepEstimates = Map<String, dynamic>.from(
          data['sleepEstimates'] as Map? ?? {},
        );
        sleepTimezones = Map<String, dynamic>.from(
          data['sleepTimezones'] as Map? ?? {},
        );
        entries = (data['entries'] as List? ?? [])
            .map(
              (e) => SleepEntry.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        notes = (data['notes'] as List? ?? [])
            .map((e) => VoiceNote.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        skipped = (data['skipped'] as List? ?? []).whereType<String>().toSet();
        reminder = data['reminder'] == true;
        bedHour = (data['bedHour'] as int? ?? 23).clamp(0, 23);
        bedMinute = (data['bedMinute'] as int? ?? 0).clamp(0, 59);
        fallingAsleepMinutes = (data['fallingAsleepMinutes'] as int? ?? 20)
            .clamp(0, 120);
      }
      ready = true;
      if (NativeExtras.available) {
        try {
          final nativeNotes = await NativeExtras.call<List>('listNotes') ?? [];
          final known = {for (final n in notes) n.file: n};
          final recovered = <VoiceNote>[];
          for (final raw in nativeNotes.whereType<Map>()) {
            final note = VoiceNote.fromJson(Map<String, dynamic>.from(raw));
            if (usesSqlite &&
                await LocalDatabase.instance.isDeleted('note', note.file)) {
              continue;
            }
            recovered.add(known[note.file] ?? note);
            if (usesSqlite && !known.containsKey(note.file)) {
              await LocalDatabase.instance.put(
                'note',
                note.file,
                note.toJson(),
                note.at.millisecondsSinceEpoch,
              );
            }
          }
          // Remote notes may not have been downloaded to this device yet.
          notes = [
            ...recovered,
            ...known.values.where(
              (n) => !recovered.any((r) => r.file == n.file),
            ),
          ];
          notes.sort((a, b) => a.at.compareTo(b.at));
          final state = await NativeExtras.call<Map>('bedtimeState');
          if (state != null) {
            error = state['error'] as String?;
            if (reminder && state['enabled'] != true && error == null) {
              error = 'Вечернее напоминание не назначено. Включи его ещё раз.';
            }
            reminder = state['enabled'] == true && error == null;
          }
        } catch (_) {
          if (reminder) {
            reminder = false;
            error = 'Не удалось проверить вечернее напоминание. Включи его ещё раз.';
          }
        }
      }
    } catch (_) {
      error = 'Не удалось прочитать дневник. Перезапусти приложение.';
    }
    _notify();
  }

  Future<void> _persist() async {
    if (!ready) throw StateError('Дневник недоступен');
    if (usesSqlite) {
      final db = LocalDatabase.instance;
      await db.setSetting('journal', {
        'skipped': skipped.toList(),
        'reminder': reminder,
        'bedHour': bedHour,
        'bedMinute': bedMinute,
        'fallingAsleepMinutes': fallingAsleepMinutes,
        'goals': goals.toJson(),
        'sleepEstimates': sleepEstimates,
        'sleepTimezones': sleepTimezones,
      });
      _notify();
      return;
    }
    final ok = await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode({
        'entries': entries.map((e) => e.toJson()).toList(),
        'notes': notes.map((e) => e.toJson()).toList(),
        'skipped': skipped.toList(),
        'reminder': reminder,
        'bedHour': bedHour,
        'bedMinute': bedMinute,
        'fallingAsleepMinutes': fallingAsleepMinutes,
        'goals': goals.toJson(),
        'sleepEstimates': sleepEstimates,
        'sleepTimezones': sleepTimezones,
      }),
    );
    if (!ok) throw StateError('Не удалось сохранить дневник');
    _notify();
  }

  Future<void> saveEntry(SleepEntry entry) async {
    if (!ready) throw StateError('Дневник недоступен');
    final previousEntry = entries
        .where((e) => e.occurrenceId == entry.occurrenceId)
        .firstOrNull;
    final previousZone = sleepTimezones[entry.occurrenceId];
    sleepTimezones[entry.occurrenceId] = {
      'bedAt': entry.bedAt.millisecondsSinceEpoch,
      'wakeAt': entry.wokeAt.millisecondsSinceEpoch,
      'bedOffsetMinutes': previousEntry?.bedAt == entry.bedAt
          ? (previousZone is Map &&
                    previousZone['bedAt'] == entry.bedAt.millisecondsSinceEpoch
                ? previousZone['bedOffsetMinutes']
                : null)
          : entry.bedAt.toLocal().timeZoneOffset.inMinutes,
      'wakeOffsetMinutes': previousEntry?.wokeAt == entry.wokeAt
          ? (previousZone is Map &&
                    previousZone['wakeAt'] ==
                        entry.wokeAt.millisecondsSinceEpoch
                ? previousZone['wakeOffsetMinutes']
                : null)
          : entry.wokeAt.toLocal().timeZoneOffset.inMinutes,
    };
    final old = entries;
    try {
      if (usesSqlite) {
        await LocalDatabase.instance.put(
          'sleep',
          entry.occurrenceId,
          entry.toJson(),
          entry.wokeAt.millisecondsSinceEpoch,
        );
      }
      entries = [
        ...entries.where((e) => e.occurrenceId != entry.occurrenceId),
        entry,
      ];
      await _persist();
    } catch (_) {
      entries = old;
      if (previousZone == null) {
        sleepTimezones.remove(entry.occurrenceId);
      } else {
        sleepTimezones[entry.occurrenceId] = previousZone;
      }
      rethrow;
    }
  }

  Future<void> skip(String occurrence) async {
    skipped.add(occurrence);
    try {
      await _persist();
    } catch (_) {
      skipped.remove(occurrence);
      rethrow;
    }
  }

  Future<void> addNote(VoiceNote note) async {
    if (!ready) throw StateError('Дневник недоступен');
    if (usesSqlite) {
      await LocalDatabase.instance.put(
        'note',
        note.file,
        note.toJson(),
        note.at.millisecondsSinceEpoch,
      );
    }
    notes = [...notes, note];
    try {
      await _persist();
    } catch (_) {
      notes.remove(note);
      rethrow;
    }
  }

  Future<void> removeNote(VoiceNote note) async {
    await NativeExtras.call<void>('deleteNote', {'file': note.file});
    final old = notes;
    notes = notes.where((n) => n.file != note.file).toList();
    try {
      if (usesSqlite) await LocalDatabase.instance.remove('note', note.file);
      await _persist();
    } catch (_) {
      notes = old;
      rethrow;
    }
  }

  Future<void> configureReminder(bool enabled, int hour, int minute) async {
    // Native scheduling must succeed before the UI reports an active reminder.
    await NativeExtras.call<void>('bedtime', {
      'enabled': enabled,
      'hour': hour,
      'minute': minute,
    });
    final old = (reminder, bedHour, bedMinute);
    reminder = enabled;
    bedHour = hour;
    bedMinute = minute;
    try {
      await _persist();
    } catch (_) {
      reminder = old.$1;
      bedHour = old.$2;
      bedMinute = old.$3;
      await NativeExtras.call<void>('bedtime', {
        'enabled': old.$1,
        'hour': old.$2,
        'minute': old.$3,
      });
      rethrow;
    }
  }

  Future<void> setFallingAsleepMinutes(int value) async {
    final previous = fallingAsleepMinutes;
    fallingAsleepMinutes = value.clamp(0, 120);
    try {
      await _persist();
    } catch (_) {
      fallingAsleepMinutes = previous;
      rethrow;
    }
  }

  bool reported(String occurrence) =>
      skipped.contains(occurrence) ||
      entries.any(
        (e) =>
            e.occurrenceId == occurrence || e.occurrences.contains(occurrence),
      );
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
