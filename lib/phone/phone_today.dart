part of 'phone_app.dart';

class _TodayPage extends StatelessWidget {
  const _TodayPage({this.updater});

  final PhoneUpdater? updater;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.habitsRevision, s.entriesRevision, s.todosRevision, s.holidays),
    );
    final today = state.today;
    final rest = state.isRestDay(today);
    final rituals = [
      for (final h in state.habits)
        if (h.onDay(today) && h.startedBy(today)) h,
    ];
    return SafeArea(
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
                      Text('${today.day} ${monthNames[today.month - 1]}', style: _title(p)),
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
            _MarksCard(title: 'RITUALS', habits: rituals, rest: rest),
            const SizedBox(height: 12),
            _MarksCard(title: 'SLEEP', habits: state.sleepHabits, rest: rest),
            const SizedBox(height: 12),
            const _TasksCard(),
          ],
        ),
      ),
    );
  }
}

class _PhoneUndoBanner extends StatefulWidget {
  const _PhoneUndoBanner({
    this.removal,
    this.canRedo = false,
    required this.onUndo,
    this.onRedo,
    required this.onHide,
  });

  final Removal? removal;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback? onRedo;
  final VoidCallback onHide;

  @override
  State<_PhoneUndoBanner> createState() => _PhoneUndoBannerState();
}

class _PhoneUndoBannerState extends State<_PhoneUndoBanner> {
  Timer? _timer;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), widget.onHide);
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_PhoneUndoBanner old) {
    super.didUpdateWidget(old);
    if (!identical(widget.removal, old.removal) || widget.canRedo != old.canRedo) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final removal = widget.removal;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: p.tile,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              removal?.label ?? 'Undone',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _body(p, size: 14),
            ),
          ),
          if (removal != null) TextButton(onPressed: widget.onUndo, child: const Text('Undo')),
          if (widget.canRedo && widget.onRedo != null) TextButton(onPressed: widget.onRedo, child: const Text('Redo')),
        ],
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
    final state = AppScope.watch(context, (s) => (s.today, s.entriesRevision));
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
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.entriesRevision, s.habitsRevision, s.holidays),
    );
    final today = state.today;
    final status = state.statusOf(today, habit);
    final streak = state.currentStreak(habit);
    final (fill, ink, icon) = switch (status) {
      HabitStatus.done => (p.done, p.onAccent, Icons.check_rounded),
      HabitStatus.missed => (p.missed, p.onAccent, Icons.close_rounded),
      HabitStatus.other => (p.other, p.onAccent, Icons.remove_rounded),
      HabitStatus.none => (p.empty, p.inkMuted, null),
    };
    final showStreak = habit.weekly == null && streak > 1;
    final canEditGoal = state.habits.any((h) => h.id == habit.id);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onLongPress: () => _showMenu(context, state, today, habit, canEditGoal: canEditGoal),
      onTap: () => habit.target != null
          ? enterRitualAmount(context, today, habit)
          : state.selectStatus(today, habit, _next[status]!),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ritualProgress(state, today, habit),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _body(p),
              ),
            ),
            if (habit.weekly != null) ...[
              Icon(Icons.event_repeat_rounded, size: 16, color: p.inkMuted),
              const SizedBox(width: 8),
            ],
            if (showStreak) ...[
              Text('$streak', style: _body(p, size: 12, colour: p.inkMuted)),
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

  Future<void> _showMenu(
    BuildContext context,
    AppState state,
    DateTime day,
    Habit habit, {
    required bool canEditGoal,
  }) async {
    final p = context.palette;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.tile,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.check_rounded, size: 18, color: p.done),
              title: Text('Mark done', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.done);
              },
            ),
            if (habit.target != null)
              ListTile(
                leading: Icon(Icons.edit_rounded, size: 18, color: p.accent),
                title: Text('Log progress', style: _body(p)),
                onTap: () {
                  Navigator.pop(sheet);
                  enterRitualAmount(context, day, habit);
                },
              ),
            ListTile(
              leading: Icon(Icons.close_rounded, size: 18, color: p.missed),
              title: Text('Mark not done', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.missed);
              },
            ),
            ListTile(
              leading: Icon(Icons.remove_rounded, size: 18, color: p.other),
              title: Text('Mark other', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.other);
              },
            ),
            ListTile(
              leading: Icon(Icons.clear_all_rounded, size: 18, color: p.inkMuted),
              title: Text('Clear mark', style: _body(p)),
              onTap: () {
                Navigator.pop(sheet);
                state.selectStatus(day, habit, HabitStatus.none);
              },
            ),
            if (canEditGoal)
              ListTile(
                leading: Icon(Icons.tune_rounded, size: 18, color: p.inkMuted),
                title: Text('Edit goal', style: _body(p)),
                onTap: () {
                  Navigator.pop(sheet);
                  editRitualGoal(context, habit, day.year, day.month);
                },
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
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision));
    final tasks = state.orderedTodos(TodoScope.today);
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
          for (final task in tasks)
            Dismissible(
              key: ValueKey('dismiss-${task.id}'),
              direction: DismissDirection.endToStart,
              confirmDismiss: task.repeatUid == null
                  ? null
                  : (_) async {
                      await confirmRemoveTask(context, TodoScope.today, task, day: state.today);
                      return false;
                    },
              onDismissed: (_) => state.removeTodo(TodoScope.today, task),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(color: p.missed, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.delete_rounded, size: 18, color: p.onAccent),
              ),
              child: SearchGlow(
                target: task.uid,
                radius: 12,
                child: _TaskRow(key: ValueKey(task.id), task: task),
              ),
            ),
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
    final state = AppScope.read(context);
    final hasMeta = task.dueTime != null || task.location != null || (!task.birthday && task.repeatUid != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: task.birthday ? () => editTask(context, TodoScope.today, task, state.today) : () => state.toggleTodo(task),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              children: [
                if (task.birthday)
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: Icon(Icons.cake_rounded, size: 18, color: p.accent),
                  )
                else
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
                        if (hasMeta)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              children: [
                                if (task.dueTime case final time?)
                                  Text(
                                    clockLabel(time),
                                    style: TextStyle(fontFamily: Fonts.taskTime, fontSize: 12, color: p.inkMuted),
                                  ),
                                if (task.location case final loc?) ...[
                                  if (task.dueTime != null) const SizedBox(width: 8),
                                  Icon(Icons.place_rounded, size: 12, color: p.inkMuted),
                                  const SizedBox(width: 2),
                                  Flexible(
                                    child: Text(
                                      loc,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _body(p, size: 12, colour: p.inkMuted),
                                    ),
                                  ),
                                ],
                                if (!task.birthday && task.repeatUid != null) ...[
                                  if (task.dueTime != null || task.location != null) const SizedBox(width: 8),
                                  Icon(Icons.repeat_rounded, size: 12, color: p.inkMuted),
                                ],
                              ],
                            ),
                          ),
                        Text(
                          task.text,
                          style: _body(p, colour: task.done ? p.inkMuted : p.ink).copyWith(
                            decoration: task.done ? TextDecoration.lineThrough : null,
                            decorationColor: p.inkMuted.withValues(alpha: 0.45),
                          ),
                        ),
                        if (task.note case final note?)
                          Text(
                            note,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: _body(p, size: 12, colour: p.inkMuted),
                          ),
                      ],
                    ),
                  ),
                ),
                TaskDetailsMenu(scope: TodoScope.today, item: task),
              ],
            ),
          ),
        ),
        for (final (i, sub) in task.subtasks.indexed)
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                HapticFeedback.selectionClick();
                state.setTodoSubtasks(TodoScope.today, task, [
                  for (final (j, s) in task.subtasks.indexed)
                    if (j == i) TodoSubtask(s.text, done: !s.done, note: s.note, numbered: s.numbered) else s,
                ]);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: sub.done ? p.done : Colors.transparent,
                        border: sub.done ? null : Border.all(color: p.inkMuted, width: 1.5),
                      ),
                      child: sub.done ? Icon(Icons.check_rounded, size: 12, color: p.onDone) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          sub.text,
                          style: _body(p, size: 14, colour: sub.done ? p.inkMuted : p.ink).copyWith(
                            decoration: sub.done ? TextDecoration.lineThrough : null,
                            decorationColor: p.inkMuted.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
    state.quickAddTodo(scope, text, dueDate: due);
    Navigator.pop(context);
  }

  Future<void> _pick() async {
    final today = AppScope.read(context).today;
    final picked = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      initialDate: _day.isBefore(today) ? today : _day,
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
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
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
              style: _body(p, size: 16),
              decoration: InputDecoration(
                hintText: 'New task',
                hintStyle: _body(p, size: 16, colour: p.inkMuted),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _save(),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _name,
              builder: (context, value, _) {
                final parsed = parseQuickTask(value.text, today, defaultDay: _day);
                if (parsed.name == value.text.trim()) return const SizedBox.shrink();
                final day = parsed.day ?? _day;
                final time = parsed.minutes;
                final actualDay = afterMidnight(time, AppScope.read(context).dayStartHour)
                    ? DateTime(day.year, day.month, day.day + 1)
                    : day;
                final details = [
                  shortDay(actualDay, today: today),
                  if (time != null) clockLabel(time),
                  ?parsed.location,
                  if (parsed.repeat case final rule?) rule.label,
                  if (parsed.until case final end?) 'Until ${shortDay(end, today: today)}',
                  for (final at in Reminder.of(parsed.reminders).map((r) => r.at(actualDay, time)))
                    'Remind ${shortDay(at, today: today)} at ${clockLabel(at.hour * 60 + at.minute)}',
                ];
                return Text(details.join(' · '), style: _body(p, size: 12, colour: p.inkMuted));
              },
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
      ),
    );
  }
}

