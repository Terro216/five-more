import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../services/sync_service.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.sync});
  final SyncService sync;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final _endpoint = TextEditingController(text: widget.sync.endpoint);
  final _recovery = TextEditingController();
  bool _working = false;
  String? _error;
  SyncService get sync => widget.sync;

  @override
  void initState() {
    super.initState();
    if (sync.signedIn) _run(sync.refreshAccount);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is SyncFailure ? e.message : 'Не удалось завершить действие. Попробуй снова или используй ключ восстановления.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _showRecovery(String? key) async {
    if (key == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          scrollable: true,
          title: const Text('Сохрани ключ восстановления'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Он вернёт доступ без почты и пароля. После восстановления ключ заменяется, прежние устройства и passkey отключаются. Сохрани его в менеджере паролей.',
              ),
              const SizedBox(height: 16),
              SelectableText(key),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: key)),
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Скопировать ключ'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Я сохранил(а) ключ'),
            ),
          ],
        ),
      ),
    );
    await sync.acknowledgeRecoveryKey();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (kIsWeb)
            const Text('Синхронизация доступна в приложении для телефона.')
          else if (!sync.signedIn) ...[
            const Text(
              'История с тобой',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'История звонков и оценки сна сохранятся на сервере и будут доступны на другом телефоне. Сервер сможет читать эти данные. Будильники работают и без аккаунта.',
              style: TextStyle(color: muted, height: 1.5),
            ),
            const SizedBox(height: 20),
            if (SyncService.defaultEndpoint.isEmpty) ...[
              TextField(
                controller: _endpoint,
                enabled: !_working,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Адрес сервера',
                  hintText: 'https://…',
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton(
              onPressed: _working
                  ? null
                  : () => _run(() async {
                      sync.configureEndpoint(_endpoint.text);
                      await _showRecovery(await sync.register());
                      await sync.sync();
                    }),
              child: const Text('Включить с passkey'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _working
                  ? null
                  : () => _run(() async {
                      sync.configureEndpoint(_endpoint.text);
                      await sync.login();
                      await sync.sync();
                    }),
              child: const Text('Войти с passkey'),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('Восстановить доступ'),
              tilePadding: EdgeInsets.zero,
              children: [
                TextField(
                  controller: _recovery,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Ключ восстановления',
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _working
                      ? null
                      : () => _run(() async {
                          sync.configureEndpoint(_endpoint.text);
                          final key = await sync.recover(_recovery.text);
                          _recovery.clear();
                          await _showRecovery(key);
                          await sync.sync();
                        }),
                  child: const Text('Восстановить'),
                ),
              ],
            ),
          ] else ...[
            if (sync.pendingRecoveryKey != null)
              FilledButton(
                onPressed: _working
                    ? null
                    : () => _run(() => _showRecovery(sync.pendingRecoveryKey)),
                child: const Text('Сохранить ключ восстановления'),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('История и оценки сна'),
              subtitle: const Text(
                'Отправлять изменения при открытом приложении',
              ),
              value: sync.enabled,
              onChanged: _working
                  ? null
                  : (value) => _run(() => sync.setEnabled(value)),
            ),
            if (sync.audioAllowed)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Загружать голосовые'),
                subtitle: const Text(
                  'Записи доступны серверу. Только для этого аккаунта.',
                ),
                value: sync.audioEnabled,
                onChanged: _working
                    ? null
                    : (value) => _run(() => sync.setAudioEnabled(value)),
              ),
            const SizedBox(height: 12),
            Text(
              sync.busy
                  ? 'Синхронизируем…'
                  : sync.lastSynced == null
                  ? 'Ещё не синхронизировано'
                  : 'Последняя синхронизация: ${sync.lastSynced!.toLocal().toString().substring(0, 16)}',
              style: const TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _working || sync.busy || !sync.enabled
                  ? null
                  : () => _run(sync.sync),
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Синхронизировать сейчас'),
            ),
            if (sync.conflicts.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Оценка изменена на двух устройствах. Какие изменения сохранить?',
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => sync.resolveConflicts(keepLocal: true),
                          ),
                    child: const Text('С этого телефона'),
                  ),
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => sync.resolveConflicts(keepLocal: false),
                          ),
                    child: const Text('С сервера'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Доступ',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: _working
                  ? null
                  : () => _run(() async {
                      await sync.register(addPasskey: true);
                    }),
              icon: const Icon(Icons.key_rounded),
              label: const Text('Добавить passkey'),
            ),
            ...sync.sessions.map(
              (session) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(session['name'] as String),
                subtitle: Text(
                  session['id'] == sync.sessionId
                      ? 'Этот сеанс'
                      : 'Другое устройство или сеанс',
                ),
                trailing: session['id'] == sync.sessionId
                    ? null
                    : IconButton(
                        tooltip: 'Отозвать доступ',
                        icon: const Icon(Icons.logout_rounded),
                        onPressed: _working
                            ? null
                            : () => _run(
                                () =>
                                    sync.revokeSession(session['id'] as String),
                              ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Идентификатор аккаунта'),
              children: [SelectableText(sync.accountId ?? '')],
            ),
            TextButton(
              onPressed: _working ? null : () => _run(sync.signOut),
              child: const Text('Выйти на этом телефоне'),
            ),
            TextButton(
              onPressed: _working
                  ? null
                  : () async {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Удалить аккаунт?'),
                          content: const Text(
                            'История и аудио на сервере будут удалены. Локальные записи и будильники останутся на телефоне. Копии в резервных архивах удаляются по сроку их хранения.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Отмена'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Удалить'),
                            ),
                          ],
                        ),
                      );
                      if (remove == true && mounted) {
                        await _run(sync.deleteAccount);
                      }
                    },
              child: const Text('Удалить аккаунт и серверную историю'),
            ),
          ],
          if (_error != null || sync.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error ?? sync.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          if (_working)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    ),
  );
}
