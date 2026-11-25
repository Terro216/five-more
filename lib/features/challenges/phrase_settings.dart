import 'package:flutter/material.dart';

import '../../app/theme.dart';
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
      _show(
        'Не удалось прочитать настройки цитат. Открой экран заново.',
        failed: true,
      );
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
      _show('Не удалось сохранить настройку. Попробуй ещё раз.', failed: true);
    }
  }

  Future<void> _refresh() async {
    _show(null);
    try {
      final result = await _library.refresh();
      switch (result.state) {
        case PhraseRefreshState.interrupted:
          _show('Загрузка остановлена. Сохранённые цитаты остались в запасе.');
        case PhraseRefreshState.recent:
          _show('Следующую порцию можно будет скачать позже.');
        case PhraseRefreshState.finished:
          final failures = result.incomplete
              .map((source) => source.label)
              .join(', ');
          final added = result.added > 0
              ? 'Добавлено цитат — ${result.added}.'
              : '';
          _show(
            failures.isEmpty
                ? (added.isEmpty ? 'Новых цитат пока нет.' : added)
                : '${added.isEmpty ? '' : '$added '}Не удалось полностью загрузить из $failures. Можно повторить позже.',
            failed: failures.isNotEmpty && result.added == 0,
          );
      }
    } catch (_) {
      _show(
        'Не удалось сохранить новые цитаты. Попробуй ещё раз.',
        failed: true,
      );
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
        title: const Text('Фразы для зеркального текста'),
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Скачивать цитаты'),
            subtitle: Text(
              _library.supportsBanter
                  ? 'Афоризмы, книги и кино из Викицитатника и Citaty.info'
                  : 'Афоризмы, книги и кино из Викицитатника',
            ),
            value: enabled,
            onChanged: canChange
                ? (value) => _update(value, _library.setEnabled)
                : null,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Пацанские цитаты'),
            subtitle: Text(
              _library.supportsBanter
                  ? 'quotes.to.digital · Возможен мат'
                  : 'Доступны в приложении на телефоне',
            ),
            value: enabled && _library.supportsBanter && _library.banterEnabled,
            onChanged: enabled && canChange && _library.supportsBanter
                ? (value) => _update(value, _library.setBanterEnabled)
                : null,
          ),
          if (enabled) ...[
            const SizedBox(height: 8),
            Text(
              count > 0
                  ? 'Цитат офлайн — $count'
                  : 'Цитаты будут доступны офлайн после загрузки.',
              style: TextStyle(color: context.palette.muted),
            ),
            TextButton.icon(
              onPressed:
                  !canChange || _library.refreshing || _library.alarmRinging
                  ? null
                  : _refresh,
              icon: const Icon(Icons.download_rounded),
              label: Text(
                _library.refreshing ? 'Скачиваем…' : 'Пополнить запас',
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
