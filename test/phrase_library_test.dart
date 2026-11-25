import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:five_more/features/challenges/challenge_models.dart';
import 'package:five_more/features/challenges/phrase_settings.dart';
import 'package:five_more/models/quote_credit.dart';
import 'package:five_more/services/phrase_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wikiText = 'Это был сюрприз!';
const _bookText = 'Книга, которую хочется открыть ещё раз.';
const _filmText = 'Карета подана, но кучер ушёл обедать.';
const _banterText = '— Волк! Сбрось настройки по умолчанию.';

http.Response _response(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/plain; charset=utf-8'},
);

http.Response _wikiResponse() => _response(
  jsonEncode({
    'parse': {
      'revid': 128,
      'text': '''
<h2>Цитаты</h2>
<table><tr class="q-text"><td>•</td><td><em>Это был</em><br>сюрприз! — <span class="q-comment">примечание</span></td></tr>
<tr class="q-author"><td></td><td>Чужая подпись</td></tr></table>
<h2>О фильме</h2>
<table><tr class="q-text"><td></td><td>Этот отзыв не цитата.</td></tr></table>
''',
    },
  }),
);

http.Response _citatyResponse({required bool book}) => _response('''
<article id="node-${book ? 42 : 43}" class="node-quote-${book ? 'book' : 'film'}">
  <div class="field-name-body"><p>${book ? _bookText : _filmText}</p></div>
  <a data-source="${book ? 'Записки кота' : 'Приключения кареты'}">Скопировать</a>
</article>
''');

class _TestPhraseLibrary extends PhraseLibrary {
  _TestPhraseLibrary(this.transport);

  final http.Client transport;

  @override
  Future<PhraseRefresh> refresh({http.Client? client}) =>
      super.refresh(client: client ?? transport);
}

void main() {
  testWidgets(
    'quote settings show partial success and only request banter after its switch',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final hosts = <String>[];
      final transport = MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == QuoteSource.wikiquote.host) {
          return _wikiResponse();
        }
        if (request.url.host == QuoteSource.banter.host) {
          return _response(jsonEncode({'id': 4040, 'quote': _banterText}));
        }
        return http.Response('', 503, headers: {'retry-after': '60'});
      });
      final library = _TestPhraseLibrary(transport);
      addTearDown(library.dispose);
      addTearDown(transport.close);
      await library.load();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [PhraseSettings(library: library)],
            ),
          ),
        ),
      );
      Future<void> tap(String text) async {
        final target = find.text(text);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tap('Фразы для зеркального текста');
      final banter = find.widgetWithText(SwitchListTile, 'Пацанские цитаты');
      expect(tester.widget<SwitchListTile>(banter).onChanged, isNull);
      await tap('Скачивать цитаты');
      expect(hosts, isEmpty);
      await tap('Пополнить запас');
      expect(find.text('Цитат офлайн — 1'), findsOneWidget);
      expect(
        find.textContaining('Не удалось полностью загрузить из Citaty.info'),
        findsOneWidget,
      );
      expect(hosts, isNot(contains(QuoteSource.banter.host)));
      hosts.clear();
      await tap('Пацанские цитаты');
      expect(hosts, isEmpty);
      await tap('Пополнить запас');
      expect(hosts, List.filled(4, QuoteSource.banter.host));
      expect(find.text('Цитат офлайн — 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'failing part of a batch keeps other quotes and credits on disk',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        final url = request.url;
        expect(url.scheme, 'https');
        expect(request.method, 'GET');
        requests.add(url);
        if (url.host == QuoteSource.wikiquote.host) {
          return requests.where((uri) => uri.host == url.host).length == 2
              ? _response('["not a Wikiquote page"]')
              : _wikiResponse();
        }
        expect(url.host, QuoteSource.citaty.host);
        expect(url.path, anyOf('/book', '/movie'));
        return url.path == '/book'
            ? _citatyResponse(book: true)
            : http.Response('', 503);
      });
      final library = PhraseLibrary();
      addTearDown(library.dispose);
      addTearDown(client.close);

      expect(
        (await library.refresh(client: client)).state,
        PhraseRefreshState.interrupted,
      );
      expect(requests, isEmpty);
      await library.setEnabled(true);
      final result = await library.refresh(client: client);
      expect(result.added, 2);
      expect(result.incomplete, [QuoteSource.wikiquote, QuoteSource.citaty]);
      expect(requests.length, 5);

      final reopened = PhraseLibrary();
      addTearDown(reopened.dispose);
      await reopened.load();
      final short = reopened.next(Random(1), ChallengeDifficulty.easy);
      expect(short.text, _wikiText);
      expect(
        short.credit!.link.toString(),
        'https://ru.wikiquote.org/w/index.php?oldid=128',
      );
      final book = reopened.next(
        Random(1),
        ChallengeDifficulty.medium,
        previous: _wikiText,
      );
      expect(book.text, _bookText);
      expect(book.credit!.title, 'Записки кота');
      expect(book.credit!.link.toString(), 'https://citaty.info/quote/42');
      expect(book.accepts('книга которую хочется открыть еще раз'), isTrue);
      expect(book.accepts('книга которую хочется открыть вновь'), isFalse);
    },
  );

  test('a separate opt-in adds banter and switching it off excludes its saved quotes', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      final host = request.url.host;
      requests.add(host);
      if (host == QuoteSource.wikiquote.host) return _wikiResponse();
      if (host == QuoteSource.citaty.host) {
        return _citatyResponse(book: request.url.path == '/book');
      }
      expect(host, QuoteSource.banter.host);
      return _response(jsonEncode({'id': 4040, 'quote': _banterText}));
    });
    addTearDown(client.close);
    final library = PhraseLibrary();
    addTearDown(library.dispose);
    await library.setEnabled(true);
    expect(library.banterEnabled, isFalse);
    expect((await library.refresh(client: client)).added, 3);
    expect(requests, isNot(contains(QuoteSource.banter.host)));

    await library.setBanterEnabled(true);
    requests.clear();
    final more = await library.refresh(client: client);
    expect(more.added, 1);
    expect(requests, List.filled(4, QuoteSource.banter.host));
    expect(library.availableCount, 4);

    final reopened = PhraseLibrary();
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.banterEnabled, isTrue);
    expect(reopened.availableCount, 4);
    expect(
      (await reopened.refresh(client: client)).state,
      PhraseRefreshState.recent,
    );
    final picked = [
      for (var seed = 0; seed < 10; seed++)
        reopened.next(Random(seed), ChallengeDifficulty.medium),
    ];
    final banter = picked.firstWhere((q) => q.text == _banterText);
    expect(banter.credit!.link.toString(), 'https://quotes.to.digital/4040');

    await reopened.setBanterEnabled(false);
    expect(reopened.availableCount, 3);
    for (var seed = 0; seed < 10; seed++) {
      expect(
        reopened.next(Random(seed), ChallengeDifficulty.medium).text,
        isNot(_banterText),
      );
    }
    await reopened.setBanterEnabled(true);
    expect(reopened.availableCount, 4);
  });

  test(
    'old downloaded phrases still work offline and web calls only Wikiquote',
    () async {
      SharedPreferences.setMockInitialValues({
        'phrases.enabled': true,
        'phrases.cache': [_filmText],
        'phrases.banter': true,
        'phrases.refreshed': DateTime.now().toIso8601String(),
      });
      final library = PhraseLibrary(browser: true);
      addTearDown(library.dispose);
      await library.load();
      expect(library.availableCount, 1);
      expect(library.next(Random(2), ChallengeDifficulty.hard).text, _filmText);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.host, QuoteSource.wikiquote.host);
        expect(request.url.queryParameters['origin'], '*');
        expect(request.headers['Api-User-Agent'], contains('FiveMore'));
        return _wikiResponse();
      });
      addTearDown(client.close);
      final result = await library.refresh(client: client);
      expect(result.added, 1);
      expect(requests, 3);
    },
  );

  for (final ring in [false, true]) {
    test(
      ring ? 'ringing stops the batch' : 'revoking consent stops the batch',
      () async {
        final library = PhraseLibrary(browser: true);
        addTearDown(library.dispose);
        await library.setEnabled(true);
        final started = Completer<void>();
        final reply = Completer<http.Response>();
        var requests = 0;
        final client = MockClient((_) {
          requests++;
          if (!started.isCompleted) started.complete();
          return reply.future;
        });
        addTearDown(client.close);
        final download = library.refresh(client: client);
        await started.future;
        if (ring) {
          library.setAlarmRinging(true);
        } else {
          await library.setEnabled(false);
        }
        reply.complete(_wikiResponse());
        expect((await download).state, PhraseRefreshState.interrupted);
        expect(requests, 1);
        expect(library.availableCount, 0);
      },
    );
  }

  test('provider backoff stops further requests and leaves the offline task usable', () async {
    final library = PhraseLibrary(browser: true);
    addTearDown(library.dispose);
    await library.setEnabled(true);
    var count = 0;
    final client = MockClient((_) async {
      count++;
      return http.Response('', 429, headers: {'retry-after': '60'});
    });
    addTearDown(client.close);
    expect((await library.refresh(client: client)).incomplete, [
      QuoteSource.wikiquote,
    ]);
    expect(
      (await library.refresh(client: client)).state,
      PhraseRefreshState.recent,
    );
    expect(count, 1);
    final fallback = library.next(Random(1), ChallengeDifficulty.extreme);
    expect(fallback.credit, isNull);
    expect(fallback.accepts(fallback.text), isTrue);
    expect(MirrorTextQuestion.clean('<script>тест тест</script>'), isNull);
    expect(MirrorTextQuestion.clean('а' * 141), isNull);
  });
}
