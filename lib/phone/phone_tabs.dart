part of 'phone_app.dart';

class _PhoneHome extends StatefulWidget {
  const _PhoneHome({super.key, this.updater});
  final PhoneUpdater? updater;

  @override
  State<_PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<_PhoneHome> {
  int _tab = 0;
  bool _redoHidden = false;
  bool _wasCanRedo = false;

  void select(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_tab == 3) AppScope.read(context).saveJournalDraft();
    setState(() => _tab = value);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.shownRemoval, s.canRedo));
    if (!state.canRedo) {
      _wasCanRedo = false;
      _redoHidden = false;
    } else if (!_wasCanRedo && state.canRedo) {
      _wasCanRedo = true;
      _redoHidden = false;
    }
    final removal = state.shownRemoval;
    final showBanner = removal != null || (state.canRedo && !_redoHidden);
    return Scaffold(
      backgroundColor: p.background,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _tab == 0 || _tab == 1
          ? FloatingActionButton(
              tooltip: 'Add task',
              backgroundColor: p.done,
              foregroundColor: p.onDone,
              elevation: 0,
              focusElevation: 0,
              hoverElevation: 0,
              highlightElevation: 0,
              onPressed: () => _tab == 0 ? _addTask(context) : addTaskAnywhere(context),
              child: const Icon(Icons.add_rounded, size: 22),
            )
          : null,
      body: Stack(
        children: [
          IndexedStack(
            index: _tab,
            children: [
              _TodayPage(updater: widget.updater),
              const PhonePlan(),
              const _WorkoutPage(),
              const SafeArea(
                child: Padding(padding: EdgeInsets.all(16), child: JournalCard()),
              ),
            ],
          ),
          if (showBanner)
            Positioned(
              left: 16,
              right: 16,
              bottom: _tab == 0 || _tab == 1 ? 84 : 16,
              child: _PhoneUndoBanner(
                removal: removal,
                canRedo: state.canRedo,
                onUndo: state.undo,
                onRedo: state.redo,
                onHide: () {
                  if (removal != null) {
                    state.hideUndoCard(removal);
                  } else {
                    setState(() => _redoHidden = true);
                  }
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.borderSoft)),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          backgroundColor: p.tile,
          surfaceTintColor: Colors.transparent,
          indicatorColor: p.done.withValues(alpha: 0.2),
          onDestinationSelected: select,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.today_rounded, size: 22), label: 'Today'),
            NavigationDestination(icon: Icon(Icons.event_note_rounded, size: 22), label: 'Plan'),
            NavigationDestination(icon: Icon(Icons.fitness_center_rounded, size: 22), label: 'Training'),
            NavigationDestination(icon: Icon(Icons.book_rounded, size: 22), label: 'Journal'),
          ],
        ),
      ),
    );
  }
}

class _WorkoutPage extends StatefulWidget {
  const _WorkoutPage();

  @override
  State<_WorkoutPage> createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<_WorkoutPage> with WidgetsBindingObserver {
  final _restLeft = ValueNotifier<int?>(null);
  Timer? _restTicker;
  bool _restChanged = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreRest());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _restTicker?.cancel();
    _restLeft.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_syncRest());
      case AppLifecycleState.paused:
        _restTicker?.cancel();
        _restTicker = null;
      default:
    }
  }

  static String _fmtNum(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  static double? _parseDecimal(String raw) {
    final cleaned = raw.trim().replaceAll(',', '.');
    if (cleaned.isEmpty) return null;
    final value = double.tryParse(cleaned);
    return value != null && value.isFinite ? value : null;
  }

  Future<void> _restoreRest() async {
    final endsAt = await PhonePlatform.restDeadline();
    if (mounted && !_restChanged && endsAt != null) _showRestCountdown(endsAt);
  }

  Future<void> _syncRest() async {
    final endsAt = await PhonePlatform.restDeadline();
    if (!mounted) return;
    if (endsAt != null) {
      _showRestCountdown(endsAt);
    } else if (_restLeft.value != null && _restLeft.value! > 0) {
      _restTicker?.cancel();
      _restTicker = null;
      _restLeft.value = null;
    }
  }

  void _showRestCountdown(DateTime endsAt) {
    _restTicker?.cancel();
    _restTicker = null;
    void tick() {
      if (!mounted) return;
      final millis = endsAt.difference(DateTime.now()).inMilliseconds;
      final left = millis <= 0 ? 0 : (millis + 999) ~/ 1000;
      _restLeft.value = left;
      if (left == 0) {
        _restTicker = null;
        return;
      }
      final rem = millis % 1000;
      final delay = (rem == 0 ? 1000 : rem) + 10;
      _restTicker = Timer(Duration(milliseconds: delay), tick);
    }

    tick();
  }

  Future<void> _startRestTimer(int seconds) async {
    if (seconds <= 0 || seconds > 3600) return;
    _restChanged = true;
    final endsAt = DateTime.now().add(Duration(seconds: seconds));
    _showRestCountdown(endsAt);
    try {
      await PhonePlatform.startRest(endsAt);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message ?? 'The rest timer sound could not be scheduled.')));
      }
    }
  }

  void _cancelRest() {
    _restChanged = true;
    _restTicker?.cancel();
    _restTicker = null;
    _restLeft.value = null;
    unawaited(PhonePlatform.cancelRest());
  }

  Future<void> _log(BuildContext context, Exercise exercise, {TrainingSet? empty}) async {
    final state = AppScope.read(context);
    final day = state.today;
    final log = state.training;
    final previous = log.lastPerformed(day, exercise);
    var reps = previous?.reps.toString() ?? '';
    var weight = (empty?.weight ?? previous?.weight)?.toString() ?? '';
    final result = await showDialog<(int, double?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final count = int.tryParse(reps.trim());
          final weightEmpty = weight.trim().isEmpty;
          final kg = _parseDecimal(weight);
          final valid =
              count != null &&
              count > 0 &&
              (exercise.bodyweight ? (weightEmpty || (kg != null && kg >= 0)) : (kg != null && kg > 0));
          return AppAlertDialog(
            title: exercise.name,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: weight,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: exercise.bodyweight ? 'Added weight (+kg, optional)' : 'Weight (kg)',
                    ),
                    onChanged: (v) => refresh(() => weight = v),
                  ),
                  TextFormField(
                    initialValue: reps,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Reps'),
                    onChanged: (v) => refresh(() => reps = v),
                  ),
                ],
              ),
            ),
            actions: [
              DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context)),
              DialogConfirm(
                label: 'Log set',
                onPressed: valid
                    ? () {
                        final n = int.tryParse(reps.trim());
                        final w = _parseDecimal(weight);
                        final wEmpty = weight.trim().isEmpty;
                        if (n != null &&
                            n > 0 &&
                            (exercise.bodyweight ? (wEmpty || (w != null && w >= 0)) : (w != null && w > 0))) {
                          Navigator.pop(context, (n, exercise.bodyweight && (wEmpty || w == 0) ? null : w));
                        }
                      }
                    : null,
              ),
            ],
          );
        },
      ),
    );
    if (result == null || !context.mounted || log.exercise(exercise.uid) == null) return;
    if (empty != null) {
      log.updateSet(empty, weight: result.$2, clearWeight: result.$2 == null, reps: result.$1);
    } else {
      log.addSet(day, exercise, reps: result.$1, loggedWeight: result.$2);
    }
    await _startRestTimer(int.tryParse(state.store.setting('restSeconds') ?? '') ?? 120);
  }

  Future<void> _editSet(BuildContext context, TrainingLog log, TrainingSet set, Exercise exercise) async {
    var weight = set.weight == null ? '' : _fmtNum(set.weight!);
    var reps = '${set.reps}';
    var effort = set.rpe == null ? '' : _fmtNum(set.rpe!);
    var note = set.note ?? '';
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          final count = int.tryParse(reps.trim());
          final weightEmpty = weight.trim().isEmpty;
          final kg = _parseDecimal(weight);
          final effortEmpty = effort.trim().isEmpty;
          final rpe = _parseDecimal(effort);
          final valid =
              count != null &&
              count > 0 &&
              (exercise.bodyweight ? (weightEmpty || (kg != null && kg >= 0)) : (kg != null && kg > 0)) &&
              (effortEmpty || (rpe != null && rpe >= 1 && rpe <= 10));
          return AppAlertDialog(
            title: exercise.name,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: weight,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: exercise.bodyweight ? 'Added weight (+kg, optional)' : 'Weight (kg)',
                    ),
                    onChanged: (v) => refresh(() => weight = v),
                  ),
                  TextFormField(
                    initialValue: reps,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Reps'),
                    onChanged: (v) => refresh(() => reps = v),
                  ),
                  TextFormField(
                    initialValue: effort,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Effort (RPE 1–10)'),
                    onChanged: (v) => refresh(() => effort = v),
                  ),
                  TextFormField(
                    initialValue: note,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Set note'),
                    onChanged: (v) => note = v,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  log.deleteSet(set);
                  Navigator.pop(ctx);
                },
                child: Text('Delete', style: TextStyle(color: ctx.palette.missedInk)),
              ),
              DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(ctx)),
              DialogConfirm(
                label: 'Save',
                onPressed: valid
                    ? () {
                        final n = int.tryParse(reps.trim());
                        final w = _parseDecimal(weight);
                        final wEmpty = weight.trim().isEmpty;
                        final r = _parseDecimal(effort);
                        final clearW = exercise.bodyweight && (wEmpty || w == 0);
                        log.updateSet(set, weight: clearW ? null : w, clearWeight: clearW, reps: n);
                        log.setDetails(
                          set,
                          note,
                          effortEmpty ? null : r,
                          addedWeight: clearW ? null : w,
                          clearWeight: clearW,
                        );
                        Navigator.pop(ctx);
                      }
                    : null,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editExercise(BuildContext context, TrainingLog log, Exercise exercise) async {
    var name = exercise.name;
    var bodyweight = exercise.bodyweight;
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          final valid = name.trim().isNotEmpty;
          return AppAlertDialog(
            title: 'Edit exercise',
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Exercise name'),
                    onChanged: (v) => refresh(() => name = v),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Bodyweight'),
                    value: bodyweight,
                    onChanged: (v) => refresh(() => bodyweight = v),
                  ),
                ],
              ),
            ),
            actions: [
              DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(ctx)),
              DialogConfirm(
                label: 'Save',
                onPressed: valid
                    ? () {
                        log.updateExercise(exercise, name: name.trim(), bodyweight: bodyweight);
                        Navigator.pop(ctx);
                      }
                    : null,
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.today, s.training.revision));
    final log = state.training;
    final session = log.session(state.today);
    final restSeconds = int.tryParse(state.store.setting('restSeconds') ?? '') ?? 120;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text('Training', style: _title(p))),
                WorkoutToolsButton(day: state.today),
                PopupMenuButton<int>(
                  tooltip: 'Rest timer',
                  icon: const Icon(Icons.timer_rounded, size: 22),
                  initialValue: restSeconds,
                  onSelected: (v) {
                    state.store.setSetting('restSeconds', v.toString());
                    if (v == 0) _cancelRest();
                    setState(() {});
                  },
                  itemBuilder: (_) => [
                    for (final seconds in [0, 60, 90, 120, 180, 300])
                      PopupMenuItem(
                        value: seconds,
                        child: Text(seconds == 0 ? 'Rest timer off' : 'Rest ${seconds ~/ 60}m ${seconds % 60}s'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (restSeconds > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ValueListenableBuilder<int?>(
                valueListenable: _restLeft,
                builder: (context, remaining, _) {
                  final running = remaining != null && remaining > 0;
                  final seconds = remaining ?? restSeconds;
                  final time = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
                  return Tile(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Icon(
                          remaining == 0 ? Icons.check_circle_outline_rounded : Icons.timer_rounded,
                          size: 18,
                          color: p.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(switch (remaining) {
                            null => 'Rest timer · $time',
                            0 => 'Rest complete',
                            _ => 'Rest $time',
                          }, style: _body(p, size: 18)),
                        ),
                        TextButton(
                          onPressed: running ? _cancelRest : () => unawaited(_startRestTimer(restSeconds)),
                          child: Text(running ? 'Cancel' : 'Start'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                for (final (exercise, sets) in session) ...[
                  () {
                    final bests = log.personalBests(state.today, exercise);
                    return Tile(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  exercise.name,
                                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 16, fontWeight: FontWeight.w600, color: p.ink),
                                ),
                              ),
                              TextButton(
                                onPressed: () =>
                                    _log(context, exercise, empty: sets.where((s) => s.reps == 0).firstOrNull),
                                child: const Text('Log set'),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Exercise options',
                                icon: Icon(Icons.more_vert_rounded, size: 18, color: p.inkMuted),
                                onSelected: (action) {
                                  if (action == 'edit') {
                                    unawaited(_editExercise(context, log, exercise));
                                  } else if (action == 'remove') {
                                    log.removeFromDay(state.today, exercise);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'edit', child: Text('Edit exercise')),
                                  PopupMenuItem(value: 'remove', child: Text('Remove from today')),
                                ],
                              ),
                            ],
                          ),
                          for (final set in sets.where((s) => s.reps > 0))
                            Dismissible(
                              key: ValueKey('set-${set.uid}'),
                              direction: DismissDirection.endToStart,
                              onDismissed: (_) => log.deleteSet(set),
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 16),
                                decoration: BoxDecoration(color: p.missed, borderRadius: BorderRadius.circular(12)),
                                child: Icon(Icons.delete_rounded, size: 18, color: p.onAccent),
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                                onTap: () => _editSet(context, log, set, exercise),
                                title: Text(
                                  exercise.bodyweight
                                      ? '${set.weight != null && set.weight! > 0 ? '+${_fmtNum(set.weight!)} kg × ' : ''}${set.reps} reps'
                                      : '${set.weight == null ? '' : '${_fmtNum(set.weight!)} kg × '}${set.reps} reps',
                                  style: _body(p, size: 15),
                                ),
                                subtitle:
                                    set.rpe != null || (set.note?.trim().isNotEmpty ?? false)
                                        ? Text(
                                            [
                                              if (set.rpe != null) 'RPE ${_fmtNum(set.rpe!)}',
                                              if (set.note?.trim().isNotEmpty ?? false) set.note!.trim(),
                                            ].join(' · '),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: _body(p, size: 12, colour: p.inkMuted),
                                          )
                                        : null,
                                trailing: bests.contains(set.uid) ? const Chip(label: Text('PB')) : null,
                              ),
                            ),
                        ],
                      ),
                    );
                  }(),
                  const SizedBox(height: 12),
                ],
                AddSessionExercise(day: state.today, logged: {for (final (e, _) in session) e.uid}),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
