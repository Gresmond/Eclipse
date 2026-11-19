part of 'phone_app.dart';

class _PhoneHome extends StatefulWidget {
  const _PhoneHome({super.key, this.updater});
  final PhoneUpdater? updater;

  @override
  State<_PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<_PhoneHome> {
  int _tab = 0;

  void select(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_tab == 3) AppScope.read(context).saveJournalDraft();
    setState(() => _tab = value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: switch (_tab) {
      0 => _TodayPage(updater: widget.updater),
      1 => const PhonePlan(),
      2 => const _WorkoutPage(),
      _ => const Scaffold(
        body: SafeArea(
          child: Padding(padding: EdgeInsets.all(16), child: JournalCard()),
        ),
      ),
    },
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: select,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
        NavigationDestination(icon: Icon(Icons.event_note), label: 'Plan'),
        NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Training'),
        NavigationDestination(icon: Icon(Icons.book_rounded), label: 'Journal'),
      ],
    ),
  );
}

class _WorkoutPage extends StatelessWidget {
  const _WorkoutPage();

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
          final count = int.tryParse(reps);
          final kg = double.tryParse(weight);
          final valid = count != null && count > 0 && (exercise.bodyweight || kg != null && kg.isFinite && kg > 0);
          return AppAlertDialog(
            title: exercise.name,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!exercise.bodyweight)
                    TextFormField(
                      initialValue: weight,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Weight (kg)'),
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
                        final n = int.tryParse(reps), w = double.tryParse(weight);
                        if (n != null && n > 0 && (exercise.bodyweight || w != null && w.isFinite && w > 0)) {
                          Navigator.pop(context, (n, exercise.bodyweight ? null : w));
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
      log.updateSet(empty, weight: result.$2, reps: result.$1);
    } else {
      log.addSet(day, exercise, reps: result.$1, loggedWeight: result.$2);
    }
    final seconds = int.tryParse(state.store.setting('restSeconds') ?? '') ?? 120;
    if (seconds == 0) return;
    try {
      await PhonePlatform.startRest(seconds);
    } on PlatformException {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Set saved. The rest timer could not start.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.training.revision));
    final log = state.training;
    final session = log.session(state.today);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Training'),
        actions: [
          WorkoutToolsButton(day: state.today),
          PopupMenuButton<int>(
            tooltip: 'Rest timer',
            icon: const Icon(Icons.timer_rounded),
            initialValue: int.tryParse(state.store.setting('restSeconds') ?? '') ?? 120,
            onSelected: (v) => state.store.setSetting('restSeconds', v.toString()),
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (exercise, sets) in session) ...[
            ListTile(
              title: Text(exercise.name),
              trailing: TextButton(
                onPressed: () => _log(context, exercise, empty: sets.where((s) => s.reps == 0).firstOrNull),
                child: const Text('Log set'),
              ),
            ),
            for (final set in sets.where((s) => s.reps > 0))
              ListTile(
                onTap: () => editSetDetails(context, set, exercise),
                dense: true,
                title: Text('${exercise.bodyweight ? '' : '${set.weight} kg × '}${set.reps} reps'),
                trailing: log.personalBests(state.today, exercise).contains(set.uid)
                    ? const Chip(label: Text('PB'))
                    : null,
              ),
          ],
          AddSessionExercise(day: state.today, logged: {for (final (e, _) in session) e.uid}),
        ],
      ),
    );
  }
}
