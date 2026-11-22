part of 'phone_app.dart';

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({this.updater});

  final PhoneUpdater? updater;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  bool _signingOut = false;

  Future<void> _signOut(AppState state, SyncService sync) async {
    if (_signingOut) return;
    setState(() => _signingOut = true);
    try {
      state.saveDrafts();
      await sync.run();
      if (!mounted) return;
      if (sync.error != null) {
        final proceed =
            await showDialog<bool>(
              context: context,
              builder: (context) => AppAlertDialog(
                title: 'Sign out without syncing?',
                content: Text(
                  'Eclipse couldn’t sync first, so unsynced changes on this phone would be lost (${sync.error}).',
                ),
                actions: [
                  DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
                  DialogConfirm(label: 'Sign out anyway', onPressed: () => Navigator.pop(context, true)),
                ],
              ),
            ) ??
            false;
        if (!proceed || !mounted) return;
      }
      await sync.turnOff();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.themeName, s.restWeekends, s.dayStartHour, s.smartAdd));
    final sync = state.sync;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.background,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Settings', style: _title(p, size: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (sync != null) ...[
            ListenableBuilder(
              listenable: sync,
              builder: (context, _) => Tile(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('SYNC', style: capsLabel(p.inkMuted)),
                    const SizedBox(height: 12),
                    Text(sync.email ?? 'Not signed in', style: _body(p)),
                    if (sync.error case final error?) ...[
                      const SizedBox(height: 6),
                      Text(error, style: _body(p, size: 14, colour: p.missedInk)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: sync.busy || _signingOut ? null : sync.run,
                          child: Text(sync.busy ? 'Syncing…' : 'Sync now'),
                        ),
                        TextButton(
                          onPressed: _signingOut ? null : () => _signOut(state, sync),
                          child: Text(_signingOut ? 'Signing out…' : 'Sign out'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Tile(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('DAYS', style: capsLabel(p.inkMuted)),
                ),
                SettingSwitchRow(
                  title: 'Smart quick-add',
                  subtitle: 'Read schedules and places from phrases like “tomorrow at 3pm at the library”.',
                  on: state.smartAdd,
                  onTap: () => state.setSmartAdd(!state.smartAdd),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => state.setRestWeekends(!state.restWeekends),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Weekends as rest days', style: _body(p)),
                              const SizedBox(height: 2),
                              Text('Saturdays and Sundays don’t count against streaks.', style: _body(p, size: 14, colour: p.inkMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SettingToggle(on: state.restWeekends),
                      ],
                    ),
                  ),
                ),
                const DayStartPicker(),
                const HolidaysRow(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Tile(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('THEME', style: capsLabel(p.inkMuted)),
                const SizedBox(height: 8),
                for (final theme in palettes)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => state.setTheme(theme.name),
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.background,
                              border: Border.all(color: theme.tileBorder),
                            ),
                            child: const SizedBox(width: 18, height: 18),
                          ),
                          const SizedBox(width: 8),
                          for (final colour in [theme.done, theme.missed, theme.other, theme.today])
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
                                child: const SizedBox(width: 12, height: 12),
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(theme.name, style: _body(p))),
                          if (theme.name == p.name) Icon(Icons.check_rounded, size: 18, color: p.accent),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.updater?.installed case final version?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Eclipse $version', style: _body(p, size: 12, colour: p.inkMuted)),
            ),
        ],
      ),
    );
  }
}
