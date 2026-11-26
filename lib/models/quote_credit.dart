import '../l10n/strings.dart';

enum QuoteSource {
  wikiquote('ru.wikiquote.org'),
  englishWikiquote('en.wikiquote.org'),
  citaty('citaty.info'),
  banter('quotes.to.digital');

  const QuoteSource(this.host);
  bool get isWikiquote => this == wikiquote || this == englishWikiquote;
  String get label => isWikiquote
      ? appStrings.wikiquote
      : (this == citaty ? 'Citaty.info' : host);
  final String host;
}

class QuoteCredit {
  const QuoteCredit({
    required this.source,
    required this.title,
    required this.link,
  });

  final QuoteSource source;
  final String title;
  final Uri link;

  Map<String, String> toJson() => {
    'source': source.name,
    'title': title,
    'url': link.toString(),
  };

  static QuoteCredit? fromJson(Object? value) {
    if (value is! Map) return null;
    final source = QuoteSource.values
        .where((s) => s.name == value['source'])
        .firstOrNull;
    final title = value['title'];
    final url = value['url'];
    if (source == null ||
        title is! String ||
        title.length > 180 ||
        url is! String ||
        url.length > 400) {
      return null;
    }
    final link = Uri.tryParse(url);
    if (link == null ||
        link.scheme != 'https' ||
        link.host != source.host ||
        link.userInfo.isNotEmpty ||
        link.port != 443) {
      return null;
    }
    return QuoteCredit(source: source, title: title, link: link);
  }
}
