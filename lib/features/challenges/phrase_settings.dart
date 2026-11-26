import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../l10n/strings.dart';
import '../../services/phrase_library.dart';

class PhraseSettings extends StatefulWidget {
  const PhraseSettings({super.key, this.library});

  final PhraseLibrary? library;

  @override
  State<PhraseSettings> createState() => _PhraseSettingsState();
}

class _PhraseSettingsState extends State<PhraseSettings> {
  PhraseLibrary get _library => widget.library ?? PhraseLibrary.instance;
  String? _status;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _library.load().catchError((Object _) {
      _show(appStrings.couldntReadQuoteSettingsReopenThisScreen, failed: true);
    });
  }

  void _show(String? status, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _failed = failed;
    });
  }

  Future<void> _update(bool value, Future<void> Function(bool) save) async {
    _show(null);
    try {
      await save(value);
    } catch (_) {
      _show(appStrings.couldntSaveTheSettingTryAgain, failed: true);
    }
  }

  Future<void> _refresh() async {
    _show(null);
    try {
      final result = await _library.refresh();
      switch (result.state) {
        case PhraseRefreshState.interrupted:
          _show(appStrings.quoteDownloadStopped);
        case PhraseRefreshState.recent:
          _show(appStrings.youCanDownloadMoreQuotesLater);
        case PhraseRefreshState.finished:
          final failures = result.incomplete
              .map((source) => source.label)
              .join(', ');
          final added = result.added > 0
              ? appStrings.quotesAdded(result.added)
              : '';
          _show(
            failures.isEmpty
                ? (added.isEmpty ? appStrings.noNewQuotesYet : added)
                : appStrings.quoteDownloadIncomplete(
                    added.isEmpty ? '' : '$added ',
                    failures,
                  ),
            failed: failures.isNotEmpty && result.added == 0,
          );
      }
    } catch (_) {
      _show(appStrings.couldntSaveTheNewQuotesTryAgain, failed: true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _library,
    builder: (context, _) {
      final canChange = _library.ready && !_library.changingSetting;
      final enabled = _library.enabled;
      final count = _library.availableCount;
      return ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(context.strings.mirrorTextPhrases),
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(context.strings.downloadQuotes),
            subtitle: Text(
              _library.english
                  ? context.strings.englishQuoteSource
                  : _library.supportsBanter
                  ? context.strings.sayingsAndQuotesFromBooksAndFilms
                  : context.strings.sayingsAndQuotesFromWikiquote,
            ),
            value: enabled,
            onChanged: canChange
                ? (value) => _update(value, _library.setEnabled)
                : null,
          ),
          if (!_library.english)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(context.strings.streetwiseQuotes),
              subtitle: Text(
                _library.supportsBanter
                    ? context.strings.quotesToDigitalMayContainStrongLanguage
                    : context.strings.availableInTheMobileApp,
              ),
              value:
                  enabled && _library.supportsBanter && _library.banterEnabled,
              onChanged: enabled && canChange && _library.supportsBanter
                  ? (value) => _update(value, _library.setBanterEnabled)
                  : null,
            ),
          if (enabled) ...[
            const SizedBox(height: 8),
            Text(
              count > 0
                  ? context.strings.offlineQuotes(count)
                  : context
                        .strings
                        .quotesWillBeAvailableOfflineAfterDownloading,
              style: TextStyle(color: context.palette.muted),
            ),
            TextButton.icon(
              onPressed:
                  !canChange || _library.refreshing || _library.alarmRinging
                  ? null
                  : _refresh,
              icon: const Icon(Icons.download_rounded),
              label: Text(
                _library.refreshing
                    ? context.strings.downloading
                    : context.strings.downloadMore,
              ),
            ),
          ],
          if (_status != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _status!,
                style: TextStyle(
                  color: _failed
                      ? Theme.of(context).colorScheme.error
                      : context.palette.muted,
                ),
              ),
            ),
        ],
      );
    },
  );
}
