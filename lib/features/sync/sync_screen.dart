import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../l10n/strings.dart';
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

  Future<void> _run(
    Future<void> Function() operation, {
    String? failureMessage,
  }) async {
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
          () => _error = e is SyncFailure
              ? e.message
              : failureMessage ?? appStrings.couldntCompleteTheActionTryAgain,
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
          title: Text(context.strings.saveYourRecoveryKey),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.strings.recoveryKeyExplanation),
              const SizedBox(height: 16),
              SelectableText(key),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: key)),
                icon: const Icon(Icons.copy_rounded),
                label: Text(context.strings.copyKey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.strings.iveSavedMyKey),
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
      appBar: AppBar(title: Text(context.strings.syncLabel)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (kIsWeb)
            Text(context.strings.syncIsAvailableInTheMobileApp)
          else if (!sync.signedIn) ...[
            Text(
              context.strings.takeYourHistoryWithYou,
              style: AppTypography.heading,
            ),
            const SizedBox(height: 12),
            Text(
              context.strings.historySyncPrivacy,
              style: TextStyle(color: context.palette.muted, height: 1.5),
            ),
            const SizedBox(height: 20),
            if (SyncService.defaultEndpoint.isEmpty) ...[
              TextField(
                controller: _endpoint,
                enabled: !_working,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: context.strings.serverAddress,
                  hintText: 'https://…',
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton(
              onPressed: _working
                  ? null
                  : () => _run(
                      () async {
                        sync.configureEndpoint(_endpoint.text);
                        await _showRecovery(await sync.register());
                        await sync.sync();
                      },
                      failureMessage: context.strings.passkeyRegistrationError,
                    ),
              child: Text(context.strings.enableWithPasskey),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _working
                  ? null
                  : () => _run(() async {
                      sync.configureEndpoint(_endpoint.text);
                      await sync.login();
                      await sync.sync();
                    }, failureMessage: context.strings.passkeySignInError),
              child: Text(context.strings.signInWithPasskey),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: Text(context.strings.recoverAccess),
              tilePadding: EdgeInsets.zero,
              children: [
                TextField(
                  controller: _recovery,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.strings.recoveryKey,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _working
                      ? null
                      : () => _run(
                          () async {
                            sync.configureEndpoint(_endpoint.text);
                            final key = await sync.recover(_recovery.text);
                            _recovery.clear();
                            await _showRecovery(key);
                            await sync.sync();
                          },
                          failureMessage: context.strings.accountRecoveryError,
                        ),
                  child: Text(context.strings.recover),
                ),
              ],
            ),
          ] else ...[
            if (sync.pendingRecoveryKey != null)
              FilledButton(
                onPressed: _working
                    ? null
                    : () => _run(() => _showRecovery(sync.pendingRecoveryKey)),
                child: Text(context.strings.saveRecoveryKey),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(context.strings.historyAndSleepRatings),
              subtitle: Text(context.strings.sendChangesWhileTheAppIsOpen),
              value: sync.enabled,
              onChanged: _working
                  ? null
                  : (value) => _run(() => sync.setEnabled(value)),
            ),
            if (sync.audioAllowed)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(context.strings.uploadVoiceRecordings),
                subtitle: Text(
                  context.strings.theServerCanReadTheseRecordingsAvailable,
                ),
                value: sync.audioEnabled,
                onChanged: _working
                    ? null
                    : (value) => _run(() => sync.setAudioEnabled(value)),
              ),
            const SizedBox(height: 12),
            Text(
              sync.busy
                  ? context.strings.syncing
                  : sync.lastSynced == null
                  ? context.strings.notSyncedYet
                  : context.strings.lastSynced(
                      appDateTime(sync.lastSynced!.toLocal()),
                    ),
              style: TextStyle(color: context.palette.muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _working || sync.busy || !sync.enabled
                  ? null
                  : () => _run(sync.sync),
              icon: const Icon(Icons.sync_rounded),
              label: Text(context.strings.syncNow),
            ),
            if (sync.conflicts.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(context.strings.ratingConflictPrompt),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => sync.resolveConflicts(keepLocal: true),
                          ),
                    child: Text(context.strings.thisPhonesVersion),
                  ),
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => _run(
                            () => sync.resolveConflicts(keepLocal: false),
                          ),
                    child: Text(context.strings.serverVersion),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Text(
              context.strings.accountAccess,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: _working
                  ? null
                  : () => _run(
                      () async {
                        await sync.register(addPasskey: true);
                      },
                      failureMessage:
                          context.strings.couldntAddAPasskeyTryAgain,
                    ),
              icon: const Icon(Icons.key_rounded),
              label: Text(context.strings.addPasskey),
            ),
            ...sync.sessions.map(
              (session) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(session['name'] as String),
                subtitle: Text(
                  session['id'] == sync.sessionId
                      ? context.strings.thisSession
                      : context.strings.anotherDeviceOrSession,
                ),
                trailing: session['id'] == sync.sessionId
                    ? null
                    : IconButton(
                        tooltip: context.strings.revokeAccess,
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
              title: Text(context.strings.accountId),
              children: [
                SelectableText(sync.accountId ?? ''),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: sync.accountId ?? ''),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(context.strings.accountIdCopied),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(context.strings.copy),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _working
                  ? null
                  : () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          scrollable: true,
                          title: Text(context.strings.signOutOnThisPhone),
                          content: Text(context.strings.signOutConfirmation),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.strings.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(context.strings.signOut),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && mounted) {
                        await _run(sync.signOut);
                      }
                    },
              child: Text(context.strings.signOutOnThisPhoneLabel),
            ),
            TextButton(
              onPressed: _working
                  ? null
                  : () async {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.strings.deleteAccount),
                          content: Text(
                            context.strings.deleteAccountConfirmation,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.strings.cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(context.strings.delete),
                            ),
                          ],
                        ),
                      );
                      if (remove == true && mounted) {
                        await _run(sync.deleteAccount);
                      }
                    },
              child: Text(context.strings.deleteAccountAndServerHistory),
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
