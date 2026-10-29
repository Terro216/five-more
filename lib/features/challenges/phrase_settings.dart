import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../services/phrase_library.dart';

class PhraseSettings extends StatefulWidget {
  const PhraseSettings({super.key});
  @override
  State<PhraseSettings> createState() => _PhraseSettingsState();
}

class _PhraseSettingsState extends State<PhraseSettings> {
  bool _busy = false;
  String? _status;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    PhraseLibrary.instance
        .load()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((Object _) {});
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _status = null;
      _failed = false;
    });
    try {
      final count = await PhraseLibrary.instance.refresh();
      if (mounted) {
        setState(
          () => _status = count == 0
              ? 'Запас уже обновлён сегодня'
              : 'В запасе $count фраз',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = 'Источник фраз не ответил. Сохранённые и встроенные фразы доступны.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('Фразы для зеркального текста'),
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Загружать новые фразы'),
        subtitle: const Text('Forismatic · русский язык'),
        value: PhraseLibrary.instance.enabled,
        onChanged: _busy && !PhraseLibrary.instance.enabled
            ? null
            : (value) async {
                setState(() => _busy = true);
                try {
                  await PhraseLibrary.instance.setEnabled(value);
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => _status =
                          'Не удалось изменить настройку. Повтори попытку.',
                    );
                  }
                }
                if (mounted) setState(() => _busy = false);
              },
      ),
      const Text(
        'Во время звонка используются только сохранённые и встроенные фразы.',
        style: TextStyle(color: muted),
      ),
      TextButton.icon(
        onPressed: _busy || !PhraseLibrary.instance.enabled ? null : _refresh,
        icon: const Icon(Icons.download_rounded),
        label: Text(_busy ? 'Загружаем…' : 'Обновить запас фраз'),
      ),
      if (_status != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _status!,
              style: TextStyle(
                color: _failed ? Theme.of(context).colorScheme.error : muted,
              ),
            ),
          ),
        ),
    ],
  );
}
