enum QuoteSource {
  wikiquote('Викицитатник', 'ru.wikiquote.org'),
  citaty('Citaty.info', 'citaty.info'),
  banter('quotes.to.digital', 'quotes.to.digital');

  const QuoteSource(this.label, this.host);
  final String label;
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
