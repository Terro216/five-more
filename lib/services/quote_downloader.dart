import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../features/challenges/challenge_models.dart';
import '../models/quote_credit.dart';

typedef QuoteBatch = ({
  List<MirrorTextQuestion> quotes,
  bool incomplete,
  Duration? retryAfter,
});

/// Fetches only the selected sources. Each host is queried sequentially.
class QuoteDownloader {
  QuoteDownloader(this._client, {required this.browser, required this.allowed});

  final http.Client _client;
  final bool browser;
  final bool Function() allowed;
  final _random = Random();

  // Use the quote template on known pages rather than arbitrary article text.
  // Rotate one author, one book and one film per refresh.
  static const _wikiPages = [
    [
      ('Козьма Прутков', 'Козьма Прутков'),
      ('Иван Андреевич Крылов', 'Иван Крылов'),
      ('Антон Павлович Чехов', 'Антон Чехов'),
    ],
    [
      ('Горе от ума', 'Александр Грибоедов · «Горе от ума»'),
      ('Евгений Онегин', 'Александр Пушкин · «Евгений Онегин»'),
    ],
    [
      ('Бриллиантовая рука', '«Бриллиантовая рука»'),
      (
        'Кавказская пленница, или Новые приключения Шурика',
        '«Кавказская пленница»',
      ),
      ('Служебный роман', '«Служебный роман»'),
      ('Кин-дза-дза!', '«Кин-дза-дза!»'),
    ],
  ];

  Future<QuoteBatch> fetch(QuoteSource source, DateTime now) async {
    final day = now.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    final List<Future<List<MirrorTextQuestion>> Function()> requests =
        switch (source) {
          QuoteSource.wikiquote => [
            for (final pages in _wikiPages)
              () => _wikiquote(pages[day % pages.length]),
          ],
          QuoteSource.citaty => [
            for (final section in ['book', 'movie'])
              () => _citaty(section, day % 20 + 1),
          ],
          QuoteSource.banter => [for (var i = 0; i < 4; i++) _banter],
        };
    final quotes = <MirrorTextQuestion>[];
    var incomplete = false;
    Duration? retryAfter;
    for (final request in requests) {
      if (!allowed()) break;
      try {
        final received = await request();
        if (!allowed()) break;
        quotes.addAll(received);
        incomplete |= received.isEmpty && source != QuoteSource.banter;
      } on _Throttled catch (error) {
        incomplete = true;
        retryAfter = error.delay;
        break;
      } on TimeoutException {
        incomplete = true;
        break;
      } on http.ClientException {
        incomplete = true;
        break;
      } on FormatException {
        incomplete = true;
      }
    }
    return (
      quotes: quotes,
      incomplete: incomplete || quotes.isEmpty,
      retryAfter: retryAfter,
    );
  }

  Future<List<MirrorTextQuestion>> _wikiquote((String, String) page) async {
    const source = QuoteSource.wikiquote;
    final body = await _get(
      Uri.https(source.host, '/w/api.php', {
        'action': 'parse',
        'page': page.$1,
        'prop': 'text|revid',
        'redirects': '1',
        'format': 'json',
        'formatversion': '2',
        'origin': '*',
        'maxlag': '5',
      }),
      maxBytes: 384000,
    );
    final data = jsonDecode(body);
    if (data is! Map) throw const FormatException('Invalid Wikiquote response');
    final error = data['error'];
    if (error is Map &&
        const ['maxlag', 'ratelimited'].contains(error['code'])) {
      throw const _Throttled(Duration(minutes: 1));
    }
    final parsed = data['parse'];
    if (parsed is! Map ||
        parsed['text'] is! String ||
        parsed['revid'] is! int) {
      throw const FormatException('Invalid Wikiquote page');
    }
    final credit = QuoteCredit(
      source: source,
      title: page.$2,
      link: Uri.https(source.host, '/w/index.php', {
        'oldid': '${parsed['revid']}',
      }),
    );
    final doc = html.parseFragment(parsed['text'] as String);
    final results = <MirrorTextQuestion>[];
    for (final node in doc.querySelectorAll('h2, tr.q-text > td:last-child')) {
      if (node.localName == 'h2') {
        final heading = node.text.trim();
        if (RegExp(r'^(О |Цитаты о |Примечания|См\. также|Ссылки)')
            .hasMatch(heading)) {
          break;
        }
        continue;
      }
      // Dialogue with speaker labels and multiple turns makes poor typing tasks.
      if (node.querySelector('b, strong')?.text.trim().endsWith(':') ?? false) {
        continue;
      }
      final annotations = node.querySelectorAll('.q-comment, sup.reference');
      for (final annotation in annotations) {
        annotation.remove();
      }
      var text = _plainText(node);
      if (annotations.isNotEmpty) {
        text = text.replaceFirst(RegExp(r'\s+[—–-]\s*$'), '');
      }
      final quote = _question(text, credit);
      if (quote != null) results.add(quote);
    }
    // Keep each page represented by a small selection of standalone excerpts.
    results.shuffle(_random);
    return {
      ...results.where((quote) => quote.text.length <= 24).take(4),
      ...results
          .where((quote) => quote.text.length > 24 && quote.text.length <= 50)
          .take(4),
      ...results,
    }.take(16).toList();
  }

  Future<List<MirrorTextQuestion>> _citaty(String section, int page) async {
    const source = QuoteSource.citaty;
    final body = await _get(
      Uri.https(source.host, '/$section', {'page': '$page'}),
      maxBytes: 320000,
    );
    final doc = html.parse(body);
    final results = <MirrorTextQuestion>[];
    final selector = section == 'book'
        ? '.node-quote-book'
        : '.node-quote-film';
    for (final node in doc.querySelectorAll('article$selector')) {
      final id = RegExp(r'^node-(\d{1,12})$').firstMatch(node.id)?.group(1);
      final paragraph = node.querySelectorAll('.field-name-body p');
      final title = node
          .querySelector('[data-source]')
          ?.attributes['data-source']
          ?.trim();
      if (id == null ||
          paragraph.length != 1 ||
          title == null ||
          title.isEmpty) {
        continue;
      }
      final quote = _question(
        _plainText(paragraph.single),
        QuoteCredit(
          source: source,
          title: title.length > 180 ? '${title.substring(0, 177)}…' : title,
          link: Uri.https(source.host, '/quote/$id'),
        ),
      );
      if (quote != null) results.add(quote);
    }
    return results.take(16).toList();
  }

  Future<List<MirrorTextQuestion>> _banter() async {
    const source = QuoteSource.banter;
    final body = await _get(
      Uri.https(source.host, '/api/random'),
      maxBytes: 16000,
    );
    final data = jsonDecode(body);
    if (data is! Map || data['quote'] is! String) {
      throw const FormatException('Invalid quote response');
    }
    final id = '${data['id']}';
    if (!RegExp(r'^\d{1,12}$').hasMatch(id)) {
      throw const FormatException('Invalid quote identifier');
    }
    final quote = _question(
      data['quote'] as String,
      QuoteCredit(
        source: source,
        title: 'Пацанская цитата',
        link: Uri.https(source.host, '/$id'),
      ),
    );
    return [?quote];
  }

  MirrorTextQuestion? _question(String value, QuoteCredit credit) {
    final text = MirrorTextQuestion.clean(value);
    return text == null ? null : MirrorTextQuestion(text, credit: credit);
  }

  String _plainText(Element node) {
    for (final br in node.querySelectorAll('br')) {
      br.replaceWith(Text(' '));
    }
    return node.text;
  }

  Future<String> _get(Uri url, {required int maxBytes}) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      url,
      abortTrigger: abort.future,
    )..followRedirects = false;
    const agent = 'FiveMore/0.8.5 (https://github.com/Terro216/five-more)';
    if (url.host == QuoteSource.wikiquote.host) {
      request.headers[browser ? 'Api-User-Agent' : 'User-Agent'] = agent;
    }
    Future<String> read() async {
      final response = await _client.send(request);
      final retryAfter = response.headers['retry-after'];
      if (response.statusCode == 429 ||
          response.statusCode == 503 && retryAfter != null) {
        final seconds = int.tryParse(retryAfter ?? '');
        throw _Throttled(
          Duration(seconds: seconds != null ? max(60, seconds) : 3600),
        );
      }
      if (response.statusCode != 200) {
        throw FormatException('HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('Quote response too large');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    }

    try {
      return await read().timeout(const Duration(seconds: 5));
    } finally {
      abort.complete();
    }
  }
}

class _Throttled implements Exception {
  const _Throttled(this.delay);
  final Duration delay;
}
