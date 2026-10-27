import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sleep_entry.dart';
import 'native_extras.dart';

class SleepJournal extends ChangeNotifier {
  static const _key = 'five_more.sleep.v1';
  List<SleepEntry> entries = [];
  List<VoiceNote> notes = [];
  Set<String> skipped = {};
  bool reminder = false;
  int bedHour = 23;
  int bedMinute = 0;
  bool ready = false;
  String? error;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
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
      }
      ready = true;
      if (NativeExtras.available) {
        try {
          final nativeNotes = await NativeExtras.call<List>('listNotes') ?? [];
          final known = {for (final n in notes) n.file: n};
          final recovered = <VoiceNote>[];
          for (final raw in nativeNotes.whereType<Map>()) {
            final note = VoiceNote.fromJson(Map<String, dynamic>.from(raw));
            recovered.add(known[note.file] ?? note);
          }
          notes = recovered;
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
    final ok = await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode({
        'entries': entries.map((e) => e.toJson()).toList(),
        'notes': notes.map((e) => e.toJson()).toList(),
        'skipped': skipped.toList(),
        'reminder': reminder,
        'bedHour': bedHour,
        'bedMinute': bedMinute,
      }),
    );
    if (!ok) throw StateError('Не удалось сохранить дневник');
    _notify();
  }

  Future<void> saveEntry(SleepEntry entry) async {
    final old = entries;
    entries = [
      ...entries.where((e) => e.occurrenceId != entry.occurrenceId),
      entry,
    ];
    try {
      await _persist();
    } catch (_) {
      entries = old;
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

  bool reported(String occurrence) =>
      skipped.contains(occurrence) ||
      entries.any((e) => e.occurrenceId == occurrence);
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
