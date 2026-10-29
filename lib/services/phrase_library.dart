import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../features/challenges/challenge_models.dart';

/// No network during a challenge. Optional refresh happens only in settings.
class PhraseLibrary {
  static final instance = PhraseLibrary();
  bool enabled = false;
  List<String> phrases = [];
  final Set<String> _seen = {};
  DateTime? refreshedAt;
  bool _loaded = false, _ringing = false;
  int _generation = 0;
  http.Client? _active;
  void setAlarmRinging(bool value) {
    _ringing = value;
    if (value) {
      _generation++;
      _active?.close();
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('phrases.enabled') ?? false;
    phrases = prefs.getStringList('phrases.cache') ?? [];
    _seen.addAll(prefs.getStringList('phrases.seen') ?? []);
    refreshedAt = DateTime.tryParse(prefs.getString('phrases.refreshed') ?? '');
    _loaded = true;
  }

  Future<void> setEnabled(bool value) async {
    if (!value) {
      _generation++;
      _active?.close();
    }
    if (!await (await SharedPreferences.getInstance()).setBool(
      'phrases.enabled',
      value,
    )) {
      throw StateError('Не удалось сохранить выбор');
    }
    enabled = value;
  }

  Future<int> refresh({http.Client? client}) async {
    await load();
    if (!enabled || _ringing || _active != null) return 0;
    final generation = _generation;
    if (refreshedAt != null &&
        DateTime.now().difference(refreshedAt!) < const Duration(hours: 24)) {
      return 0;
    }
    final owned = client == null;
    final transport = client ?? http.Client();
    _active = transport;
    bool allowed() => enabled && !_ringing && generation == _generation;
    final fresh = <String>{};
    try {
      // A small bounded batch. No identifiers, audio, or diary data leave the device.
      for (var i = 0; i < 6; i++) {
        if (!allowed()) return 0;
        final phrase = await _fetch(transport)
            .timeout(const Duration(seconds: 5));
        if (!allowed()) return 0;
        if (phrase != null) fresh.add(phrase);
      }
      if (fresh.isEmpty) throw StateError('Источник не вернул подходящих фраз');
      final next = {...fresh, ...phrases}.take(200).toList();
      final prefs = await SharedPreferences.getInstance();
      if (!allowed()) return 0;
      if (!await prefs.setStringList('phrases.cache', next)) {
        throw StateError('Не удалось сохранить фразы');
      }
      phrases = next;
      refreshedAt = DateTime.now();
      await prefs.setString(
        'phrases.refreshed',
        refreshedAt!.toIso8601String(),
      );
      return phrases.length;
    } finally {
      _active = null;
      if (owned) transport.close();
    }
  }

  Future<String?> _fetch(http.Client client) async {
    final request = http.Request(
      'GET',
      Uri.https('api.forismatic.com', '/api/1.0/', {
        'method': 'getQuote',
        'format': 'json',
        'lang': 'ru',
        'key': '${Random().nextInt(1000000)}',
      }),
    )..followRedirects = false;
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw StateError('Источник фраз недоступен');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 16000) {
        throw StateError('Некорректный ответ источника');
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    return data is Map ? sanitize(data['quoteText']) : null;
  }

  static String? sanitize(Object? value) {
    if (value is! String) return null;
    final phrase = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (phrase.length < 12 ||
        phrase.length > 140 ||
        RegExp(
          r'[<>\x00-\x1F\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]|https?://',
        ).hasMatch(phrase)) {
      return null;
    }
    if (!RegExp(r'[а-яА-ЯёЁ]').hasMatch(phrase)) return null;
    return phrase;
  }

  MirrorTextQuestion next(
    Random random,
    ChallengeDifficulty difficulty, {
    String? previous,
  }) {
    final maxLength = [24, 50, 90, 140][difficulty.index];
    final pool = <String>{
      if (enabled)
        ...phrases.where(
          (p) =>
              p.length <= maxLength && (difficulty.index < 2 || p.length >= 30),
        ),
      for (var seed = 0; seed < 30; seed++)
        generateMirrorTextQuestion(Random(seed), difficulty).text,
    }.toList();
    var choices = pool
        .where((p) => p != previous && !_seen.contains(p))
        .toList();
    if (choices.isEmpty) {
      _seen.removeAll(pool);
      choices = pool.where((p) => p != previous).toList();
    }
    final text = choices[random.nextInt(choices.length)];
    _seen.add(text);
    _saveSeen();
    return MirrorTextQuestion(text);
  }

  Future<void> _saveSeen() async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        'phrases.seen',
        _seen.toList().reversed.take(500).toList(),
      );
    } catch (_) {
      /* Fallback tasks must stay usable if storage is unavailable. */
    }
  }
}
