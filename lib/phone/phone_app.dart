import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../data/app_log.dart';
import '../data/backups.dart';
import '../data/data_folder.dart';
import '../data/google_drive.dart';
import '../data/journal_files.dart';
import '../data/store.dart';
import '../data/sync_service.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_dialog.dart';
import '../widgets/tile.dart';
import 'phone_platform.dart';

/// The phone's Eclipse: today's rituals, sleep and tasks, and adding tasks,
/// on the same data as the computers through Drive sync.
Future<void> phoneMain() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  AppLog.start(dir);
  final documents = await getApplicationDocumentsDirectory();
  final data = DataFolder.load(dir, documents);
  await data.root.create(recursive: true);
  final backups = Backups(data.backups)..beforeUpdating(data.database);
  final store = Store.open(data.database);
  final sync = SyncService.load(dir, store);
  final state = AppState(store, backups: backups, journalFiles: JournalFiles(data.journal), dataFolder: data, sync: sync);
  state.endTour();
  sync.start();
  if (sync.isOn) unawaited(sync.run());
  runApp(PhoneApp(state: state, updater: PhoneUpdater()));
}

class PhoneApp extends StatefulWidget {
  const PhoneApp({super.key, required this.state, this.updater, this.schedule = PhonePlatform.schedule});

  final AppState state;
  final PhoneUpdater? updater;

  /// Sets the reminders as alarms; stands in for the phone in tests.
  final Future<void> Function(AppState) schedule;

  @override
  State<PhoneApp> createState() => _PhoneAppState();
}

class _PhoneAppState extends State<PhoneApp> with WidgetsBindingObserver {
  AppState get _state => widget.state;
  Timer? _scheduling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(_changed);
    _changed();
    unawaited(widget.updater?.check());
  }

  @override
  void dispose() {
    _scheduling?.cancel();
    _state.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Puts the alarms right once a burst of changes has settled.
  void _changed() {
    _scheduling?.cancel();
    _scheduling = Timer(const Duration(seconds: 1), () => unawaited(widget.schedule(_state).catchError((Object _) {})));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final sync = _state.sync;
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        _state.checkDate();
        if (sync != null && sync.isOn) unawaited(sync.run());
        unawaited(widget.updater?.check());
      case AppLifecycleState.paused:
        // What was just ticked reaches the computers before Android stops it.
        _state.saveDrafts();
        if (sync != null && sync.isOn) unawaited(sync.run());
      default:
    }
  }

  @override
  Widget build(BuildContext context) => AppScope(
    state: _state,
    child: ValueListenableBuilder<String?>(
      valueListenable: _state.themeNotifier,
      builder: (context, themeName, _) => MaterialApp(
        title: 'Eclipse',
        debugShowCheckedModeBanner: false,
        theme: themeNamed(themeName),
        themeAnimationDuration: Motion.morph,
        themeAnimationCurve: Motion.morphCurve,
        builder: (context, child) => DefaultTextHeightBehavior(
          textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
          child: ThemeMorph(target: paletteNamed(themeName), child: child!),
        ),
        home: _state.sync == null
            ? _TodayPage(updater: widget.updater)
            : ListenableBuilder(
                listenable: _state.sync!,
                builder: (context, _) =>
                    _state.sync!.isOn ? _TodayPage(updater: widget.updater) : _SignInPage(sync: _state.sync!),
              ),
      ),
    ),
  );
}

/// Text as on a computer: Regular, at the tasks' line height.
TextStyle _body(Palette p, {double size = 15, Color? colour}) =>
    TextStyle(fontFamily: Fonts.body, fontSize: size, fontWeight: FontWeight.w400, height: 1.35, color: colour ?? p.ink);

/// The big date and page titles, as a computer's header sets them.
TextStyle _title(Palette p, {double size = 38}) => TextStyle(
  fontFamily: Fonts.display,
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: -0.6,
  height: 1.05,
  color: p.ink,
);

/// The first thing on a new phone: there's nothing here until it's joined.
class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.sync});

  final SyncService sync;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final sync = widget.sync;
    try {
      final GoogleAccount account = await sync.signIn();
      unawaited(PhonePlatform.toFront());
      final others = await sync.look(account);
      if (others && !sync.isReturning(account)) {
        if (sync.needsAccountChoice(account) && !await _confirmReplace(account.email)) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        await sync.turnOn(account, join: true);
      } else {
        await sync.turnOn(account, join: false);
      }
      unawaited(PhonePlatform.askNotifications());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _confirmReplace(String email) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
          title: 'Use this account’s data?',
          content: Text('What’s on this phone is replaced with what’s in $email.'),
          actions: [
            DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context, false)),
            DialogConfirm(label: 'Use it', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('Eclipse', style: _title(p)),
              const SizedBox(height: 12),
              Text(
                'Sign in with the same Google account as your computers to bring your rituals and tasks here.',
                style: _body(p, colour: p.inkMuted),
              ),
              const SizedBox(height: 24),
              if (_error case final error?) ...[
                Text(error, style: _body(p, size: 14, colour: p.missedInk)),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _busy ? null : _signIn,
                style: FilledButton.styleFrom(
                  backgroundColor: p.done,
                  foregroundColor: p.onDone,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: Text(_busy ? 'Waiting for Google…' : 'Sign in with Google'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _TodayPage extends StatelessWidget {
  const _TodayPage({this.updater});

  final PhoneUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.habitsRevision, s.entriesRevision, s.todosRevision));
    final today = state.today;
    final rest = state.isRestDay(today);
    return Scaffold(
      backgroundColor: p.background,
      // 16 under it, and the list leaves 16 over it above its last card.
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add task',
        backgroundColor: p.done,
        foregroundColor: p.onDone,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        onPressed: () => _addTask(context),
        child: const Icon(Icons.add_rounded, size: 22),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: p.accent,
          onRefresh: () async {
            final sync = state.sync;
            if (sync != null && sync.isOn) await sync.run();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(weekdayNames[today.weekday - 1].toUpperCase(), style: capsLabel(p.inkMuted)),
                        const SizedBox(height: 4),
                        Text(
                          '${today.day} ${monthNames[today.month - 1]}',
                          style: _title(p),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    icon: Icon(Icons.settings_rounded, color: p.inkMuted),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => _SettingsPage(updater: updater)),
                    ),
                  ),
                ],
              ),
              if (updater case final updater?) _UpdateCard(updater: updater),
              const SizedBox(height: 16),
              _MarksCard(title: 'RITUALS', habits: state.habits, rest: rest),
              const SizedBox(height: 12),
              _MarksCard(title: 'SLEEP', habits: state.sleepHabits, rest: rest),
              const SizedBox(height: 12),
              const _TasksCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.updater});

  final PhoneUpdater updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final version = updater.available;
        if (version == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Tile(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(updater.error ?? 'Eclipse $version is out', style: _body(p, size: 14))),
                TextButton(
                  onPressed: updater.updating ? null : updater.update,
                  child: Text(updater.updating ? 'Downloading…' : 'Update'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Rituals or the sleep schedule: each a row with its mark for today.
class _MarksCard extends StatelessWidget {
  const _MarksCard({required this.title, required this.habits, required this.rest});

  final String title;
  final List<Habit> habits;
  final bool rest;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (habits.isEmpty) return const SizedBox.shrink();
    final done = habits.where((h) => state.statusOf(state.today, h) == HabitStatus.done).length;
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: title,
            titleStyle: capsLabel(context.palette.inkMuted),
            caption: rest ? 'Rest day' : '$done of ${habits.length}',
          ),
          const SizedBox(height: 8),
          for (final h in habits) _MarkRow(habit: h),
        ],
      ),
    );
  }
}

/// Tapping goes round as on a computer: blank, done, not done, other.
class _MarkRow extends StatelessWidget {
  const _MarkRow({required this.habit});

  final Habit habit;

  static const _next = {
    HabitStatus.none: HabitStatus.done,
    HabitStatus.done: HabitStatus.missed,
    HabitStatus.missed: HabitStatus.other,
    HabitStatus.other: HabitStatus.none,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final today = state.today;
    final status = state.statusOf(today, habit);
    final streak = state.currentStreak(habit);
    final (fill, ink, icon) = switch (status) {
      HabitStatus.done => (p.done, p.onDone, Icons.check_rounded),
      HabitStatus.missed => (p.missed, p.missedInk, Icons.close_rounded),
      HabitStatus.other => (p.other, p.otherInk, Icons.remove_rounded),
      HabitStatus.none => (p.empty, p.inkMuted, null),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => state.selectStatus(today, habit, _next[status]!),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: Text(habit.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: _body(p)),
            ),
            if (streak > 1) ...[
              Text('$streak', style: _body(p, size: 13, colour: p.inkMuted)),
              const SizedBox(width: 12),
            ],
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12)),
              child: icon == null ? null : Icon(icon, size: 22, color: ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _TasksCard extends StatelessWidget {
  const _TasksCard();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final tasks = [...state.todos[TodoScope.today]!];
    int order(TodoItem t) => t.done ? 2 : (t.dueTime == null ? 1 : 0);
    tasks.sort((a, b) {
      final first = order(a).compareTo(order(b));
      return first != 0 ? first : (a.dueTime ?? 0).compareTo(b.dueTime ?? 0);
    });
    return Tile(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TileHeader(
            title: 'TODAY',
            titleStyle: capsLabel(p.inkMuted),
            caption: switch (tasks.where((t) => !t.done).length) {
              0 => null,
              final open => '$open to do',
            },
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Nothing planned', style: _body(p, colour: p.inkMuted)),
            ),
          for (final task in tasks) _TaskRow(key: ValueKey(task.id), task: task),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({super.key, required this.task});

  final TodoItem task;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => state.toggleTodo(task),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: task.done ? p.done : Colors.transparent,
                border: task.done ? null : Border.all(color: p.inkMuted, width: 1.5),
              ),
              child: task.done ? Icon(Icons.check_rounded, size: 18, color: p.onDone) : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (task.dueTime case final time?)
                      Text(
                        clockLabel(time),
                        style: TextStyle(fontFamily: Fonts.taskTime, fontSize: 12, color: p.inkMuted),
                      ),
                    Text(
                      task.text,
                      style: _body(p, colour: task.done ? p.inkMuted : p.ink).copyWith(
                        decoration: task.done ? TextDecoration.lineThrough : null,
                        decorationColor: p.inkMuted.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A task's name and day: today, tomorrow or one picked.
Future<void> _addTask(BuildContext context) async {
  final state = AppScope.read(context);
  final p = context.palette;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.tile,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => AppScope(state: state, child: const _AddTaskSheet()),
  );
}

class _AddTaskSheet extends StatefulWidget {
  const _AddTaskSheet();

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final _name = TextEditingController();
  late DateTime _day = AppScope.read(context).today;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final text = _name.text.trim();
    if (text.isEmpty) return;
    final state = AppScope.read(context);
    final (scope, due) = scopeForDay(state.today, _day);
    state.addTodo(scope, text, dueDate: due);
    Navigator.pop(context);
  }

  Future<void> _pick() async {
    final today = AppScope.read(context).today;
    final picked = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      initialDate: _day,
    );
    if (picked != null && mounted) setState(() => _day = picked);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final today = AppScope.read(context).today;
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final picked = _day != today && _day != tomorrow;
    Widget chip(String label, bool on, VoidCallback onTap) => ChoiceChip(
      label: Text(label, style: _body(p, size: 14, colour: on ? p.onDone : p.ink)),
      selected: on,
      showCheckmark: false,
      selectedColor: p.done,
      backgroundColor: p.empty,
      side: BorderSide.none,
      onSelected: (_) => onTap(),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            cursorColor: p.ink,
            style: _body(p, size: 17),
            decoration: InputDecoration(
              hintText: 'New task',
              hintStyle: _body(p, size: 17, colour: p.inkMuted),
              border: InputBorder.none,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: [
                    chip('Today', _day == today, () => setState(() => _day = today)),
                    chip('Tomorrow', _day == tomorrow, () => setState(() => _day = tomorrow)),
                    chip(picked ? shortDay(_day, today: today) : 'Pick a day', picked, _pick),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: 'Add',
                style: IconButton.styleFrom(backgroundColor: p.done, foregroundColor: p.onDone),
                onPressed: _save,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({this.updater});

  final PhoneUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => s.themeName);
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
          if (sync != null)
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
                    Row(
                      children: [
                        TextButton(onPressed: sync.run, child: const Text('Sync now')),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            await sync.turnOff();
                            if (context.mounted) Navigator.pop(context);
                          },
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ],
                ),
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
                          if (theme.name == p.name) Icon(Icons.check_rounded, size: 18, color: p.ink),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (updater?.installed case final version?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Eclipse $version', style: _body(p, size: 13, colour: p.inkMuted)),
            ),
        ],
      ),
    );
  }
}
