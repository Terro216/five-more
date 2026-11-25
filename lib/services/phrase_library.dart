import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../features/challenges/challenge_models.dart';
import '../models/quote_credit.dart';
import 'quote_downloader.dart';

enum PhraseRefreshState { finished, recent, interrupted }

class PhraseRefresh {
  const PhraseRefresh(this.state, {this.added = 0, this.incomplete = const []});

  final PhraseRefreshState state;
  final int added;
  final List<QuoteSource> incomplete;
}

typedef _SourceCache = ({
  List<MirrorTextQuestion> quotes,
  DateTime? refreshAfter,
});

/// Downloads happen only on demand in settings. Challenges read local text.
class PhraseLibrary extends ChangeNotifier {
  PhraseLibrary({this.browser = kIsWeb});

  static final instance = PhraseLibrary();
  static const _cacheKey = 'phrases.quotes.v2';
  final bool browser;
  bool get supportsBanter => !browser;

  SharedPreferences? _prefs;
  Future<void>? _loading;
  bool _enabled = false, _banterEnabled = false, _ringing = false;
  bool _changingSetting = false;
  int _generation = 0;
  http.Client? _active;
  final Set<String> _seen = {};
  var _cache = <QuoteSource, _SourceCache>{};
  var _legacy = <MirrorTextQuestion>[];

  bool get ready => _prefs != null;
  bool get enabled => _enabled;
  bool get banterEnabled => _banterEnabled;
  bool get alarmRinging => _ringing;
  bool get refreshing => _active != null;
  bool get changingSetting => _changingSetting;

  Iterable<QuoteSource> get _selectedSources => [
    QuoteSource.wikiquote,
    if (!browser) QuoteSource.citaty,
    if (supportsBanter && _banterEnabled) QuoteSource.banter,
  ];

  Iterable<MirrorTextQuestion> get _downloaded sync* {
    for (final source in _selectedSources) {
      yield* _cache[source]?.quotes ?? const [];
    }
    yield* _legacy;
  }

  int get availableCount => _downloaded
      .map((q) => MirrorTextQuestion.answerKey(q.text))
      .toSet()
      .length;

  void setAlarmRinging(bool value) {
    if (_ringing == value) return;
    _ringing = value;
    if (value) _cancelRefresh();
    notifyListeners();
  }

  void _cancelRefresh() {
    _generation++;
    _active?.close();
  }

  Future<void> load() => ready
      ? Future.value()
      : _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('phrases.enabled') ?? false;
    _banterEnabled = prefs.getBool('phrases.banter') ?? false;
    _legacy = [
      for (final value in prefs.getStringList('phrases.cache') ?? [])
        if (MirrorTextQuestion.clean(value) case final text?)
          MirrorTextQuestion(text),
    ].take(200).toList();
    _seen.addAll(
      (prefs.getStringList('phrases.seen') ?? [])
          .take(500)
          .toList()
          .reversed
          .map(MirrorTextQuestion.answerKey),
    );
    try {
      final raw = jsonDecode(prefs.getString(_cacheKey) ?? '{}');
      if (raw is Map) {
        for (final source in QuoteSource.values) {
          final stored = raw[source.name];
          if (stored is! Map || stored['quotes'] is! List) continue;
          final quotes = <MirrorTextQuestion>[];
          for (final entry in (stored['quotes'] as List).whereType<Map>().take(
            _limit(source),
          )) {
            final value = entry['text'];
            final credit = QuoteCredit.fromJson(entry['credit']);
            final text = value is String
                ? MirrorTextQuestion.clean(value)
                : null;
            if (credit?.source == source && text != null) {
              quotes.add(MirrorTextQuestion(text, credit: credit));
            }
          }
          final until = stored['refreshAfter'];
          _cache[source] = (
            quotes: quotes,
            refreshAfter: until is String ? DateTime.tryParse(until) : null,
          );
        }
      }
    } on FormatException {
      // A damaged download must not stop the built-in or previously saved tasks.
    }
    _prefs = prefs;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) =>
      _setPreference('phrases.enabled', value, (saved) => _enabled = saved);

  Future<void> setBanterEnabled(bool value) async {
    if (!supportsBanter) return;
    await _setPreference(
      'phrases.banter',
      value,
      (saved) => _banterEnabled = saved,
    );
  }

  Future<void> _setPreference(
    String key,
    bool value,
    ValueChanged<bool> apply,
  ) async {
    await load();
    if (_changingSetting) return;
    _changingSetting = true;
    if (!value) _cancelRefresh();
    notifyListeners();
    try {
      if (!await _prefs!.setBool(key, value)) {
        throw StateError('Не удалось сохранить выбор');
      }
      apply(value);
    } finally {
      _changingSetting = false;
      notifyListeners();
    }
  }

  Future<PhraseRefresh> refresh({http.Client? client}) async {
    await load();
    const interrupted = PhraseRefresh(PhraseRefreshState.interrupted);
    if (!enabled || _ringing || refreshing || changingSetting) {
      return interrupted;
    }
    final now = DateTime.now();
    final sources = _selectedSources.where((source) {
      final next = _cache[source]?.refreshAfter;
      return next == null || !now.isBefore(next);
    }).toList();
    if (sources.isEmpty) return const PhraseRefresh(PhraseRefreshState.recent);

    final generation = _generation;
    final transport = client ?? http.Client();
    _active = transport;
    bool allowed() => enabled && !_ringing && generation == _generation;
    notifyListeners();
    try {
      final before = _downloaded
          .map((q) => MirrorTextQuestion.answerKey(q.text))
          .toSet();
      final download = QuoteDownloader(
        transport,
        browser: browser,
        allowed: allowed,
      );
      final batches = await Future.wait(
        sources.map((source) => download.fetch(source, now)),
      );
      if (!allowed()) return interrupted;
      final next = Map<QuoteSource, _SourceCache>.of(_cache);
      final incomplete = <QuoteSource>[];
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i];
        final batch = batches[i];
        if (batch.incomplete) incomplete.add(source);
        if (batch.quotes.isEmpty && batch.retryAfter == null) continue;
        final quotes = <String, MirrorTextQuestion>{};
        for (final quote in [...batch.quotes, ...?_cache[source]?.quotes]) {
          quotes.putIfAbsent(
            MirrorTextQuestion.answerKey(quote.text),
            () => quote,
          );
        }
        final delay =
            batch.retryAfter ??
            (batch.incomplete ? Duration.zero : const Duration(hours: 24));
        next[source] = (
          quotes: quotes.values.take(_limit(source)).toList(),
          refreshAfter: DateTime.now().add(delay),
        );
      }
      if (batches.any(
        (batch) => batch.quotes.isNotEmpty || batch.retryAfter != null,
      )) {
        final written = await _prefs!.setString(
          _cacheKey,
          jsonEncode({
            for (final entry in next.entries)
              entry.key.name: {
                'refreshAfter': entry.value.refreshAfter?.toIso8601String(),
                'quotes': [
                  for (final quote in entry.value.quotes)
                    {'text': quote.text, 'credit': quote.credit!.toJson()},
                ],
              },
          }),
        );
        if (!written) throw StateError('Не удалось сохранить цитаты');
        _cache = next;
      }
      if (!allowed()) return interrupted;
      final after = _downloaded
          .map((q) => MirrorTextQuestion.answerKey(q.text))
          .toSet();
      return PhraseRefresh(
        PhraseRefreshState.finished,
        added: after.difference(before).length,
        incomplete: incomplete,
      );
    } catch (_) {
      if (!allowed()) return interrupted;
      rethrow;
    } finally {
      if (client == null) transport.close();
      _active = null;
      notifyListeners();
    }
  }

  static int _limit(QuoteSource source) =>
      source == QuoteSource.banter ? 60 : 160;

  MirrorTextQuestion next(
    Random random,
    ChallengeDifficulty difficulty, {
    String? previous,
  }) {
    final maxLength = [24, 50, 90, 140][difficulty.index];
    final minLength = [12, 12, 30, 55][difficulty.index];
    final pool = <String, MirrorTextQuestion>{};
    if (enabled) {
      for (final quote in _downloaded) {
        if (quote.text.length >= minLength && quote.text.length <= maxLength) {
          pool.putIfAbsent(
            MirrorTextQuestion.answerKey(quote.text),
            () => quote,
          );
        }
      }
    }
    final downloadedKeys = pool.keys.toSet();
    for (var seed = 0; seed < 30; seed++) {
      final quote = generateMirrorTextQuestion(Random(seed), difficulty);
      pool.putIfAbsent(MirrorTextQuestion.answerKey(quote.text), () => quote);
    }
    final excluded = MirrorTextQuestion.answerKey(previous ?? '');
    var choices = pool.keys
        .where((key) => key != excluded && !_seen.contains(key))
        .toList();
    if (choices.isEmpty) {
      _seen.removeAll(pool.keys);
      choices = pool.keys.where((key) => key != excluded).toList();
    }

    final downloaded = choices.where(downloadedKeys.contains).toList();
    if (downloaded.isNotEmpty) {
      final regular = downloaded
          .where((key) => pool[key]!.credit?.source != QuoteSource.banter)
          .toList();
      final banter = downloaded
          .where((key) => pool[key]!.credit?.source == QuoteSource.banter)
          .toList();
      choices = banter.isNotEmpty && (regular.isEmpty || random.nextInt(4) == 0)
          ? banter
          : regular;
    }
    final key = choices[random.nextInt(choices.length)];
    _seen.add(key);
    if (_seen.length > 500) _seen.remove(_seen.first);
    unawaited(_saveSeen());
    return pool[key]!;
  }

  Future<void> _saveSeen() async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        'phrases.seen',
        _seen.toList().reversed.toList(),
      );
    } catch (_) {
      // A storage failure must not interrupt a challenge.
    }
  }
}
