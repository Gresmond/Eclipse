import 'app_dialog.dart';

import 'package:flutter/material.dart';

import '../data/sync_service.dart';
import '../theme/app_theme.dart';

class PassphrasePage extends StatelessWidget {
  const PassphrasePage({super.key, required this.submit});
  final void Function(String?) submit;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: themeNamed(null),
    home: Scaffold(
      body: Center(child: PassphraseDialog(onSubmit: submit)),
    ),
  );
}

class PassphraseDialog extends StatefulWidget {
  const PassphraseDialog({super.key, this.creating = false, this.onSubmit});
  final bool creating;
  final void Function(String?)? onSubmit;
  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  String phrase = '', repeat = '';
  void finish(String? value) {
    if (widget.onSubmit case final callback?) {
      callback(value);
    } else {
      Navigator.pop(context, value);
    }
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: widget.creating ? 'Encrypt Drive files' : 'Unlock Drive files',
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.creating)
            const Text(
              'Keep a copy of your passphrase. Each device needs it once. New hidden sync files and backups are encrypted. Earlier backups and the readable journal folder keep their existing format.',
            ),
          TextField(
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Passphrase'),
            onChanged: (v) => setState(() => phrase = v),
          ),
          if (widget.creating)
            TextField(
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Confirm passphrase'),
              onChanged: (v) => setState(() => repeat = v),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => finish(null), child: const Text('Cancel')),
      FilledButton(
        onPressed: phrase.isEmpty || widget.creating && (phrase.length < 12 || repeat != phrase)
            ? null
            : () => finish(phrase),
        child: Text(widget.creating ? 'Enable encryption' : 'Unlock'),
      ),
    ],
  );
}

class DriveEncryptionButton extends StatefulWidget {
  const DriveEncryptionButton({super.key, required this.sync});
  final SyncService sync;
  @override
  State<DriveEncryptionButton> createState() => _DriveEncryptionButtonState();
}

class _DriveEncryptionButtonState extends State<DriveEncryptionButton> {
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: busy || widget.sync.vaultUnlocked
            ? null
            : () async {
                setState(() => busy = true);
                try {
                  await widget.sync.configureVault(
                    (creating) => showAppDialog<String>(
                      context: context,
                      builder: (_) => PassphraseDialog(creating: creating),
                    ),
                  );
                  if (mounted) setState(() => error = null);
                } catch (e) {
                  if (mounted) setState(() => error = e.toString());
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
        child: Text(
          busy
              ? 'Opening Drive…'
              : widget.sync.vaultUnlocked
              ? 'Drive encryption enabled'
              : 'Drive file encryption',
        ),
      ),
      if (error != null) Text(error!),
    ],
  );
}
