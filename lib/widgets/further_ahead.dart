part of 'todo_panel.dart';

/// Tasks more than a week away, under their days (only days with any),
/// and the next time each repeating task comes round after the week.
class FurtherAheadCard extends StatefulWidget {
  const FurtherAheadCard({super.key});

  @override
  State<FurtherAheadCard> createState() => _FurtherAheadCardState();
}

class _FurtherAheadCardState extends State<FurtherAheadCard> with _NewTasks {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay, s.laterBirthdays));
    final day = state.shownDay;
    final past = state.viewDay != null;
    final planned = _Planned(state, day, past: past);
    // Birthdays are only known from today on, so a past day leaves them out.
    final birthdays = state.laterBirthdays && !past;
    bool shows(_Later later) => birthdays || !(later.item?.birthday ?? later.repeat!.birthday);
    final groups = [
      for (final (date, items) in [
        for (final (date, items) in planned.later) (date as DateTime?, items),
        if (planned.undated.isNotEmpty) (null, planned.undated),
      ])
        if (items.where(shows).toList() case final shown when shown.isNotEmpty) (date, shown),
    ];
    final count = groups.fold(0, (n, g) => n + g.$2.length);
    // Hidden birthdays count as seen, so showing them doesn't fade them in.
    final added = _added(day, [
      for (final (_, items) in [...planned.later, (null, planned.undated)])
        for (final later in items)
          if (later.item case final item?) item.id,
    ]);
    final today = state.today;

    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TileHeader(
              title: 'Further ahead',
              caption: '$count planned',
              trailingAtEnd: true,
              trailing: AnimatedOpacity(
                opacity: past ? 0 : 1,
                duration: Motion.morph,
                curve: Motion.morphCurve,
                child: IgnorePointer(
                  ignoring: past,
                  child: _ShowToggle(
                    icon: _birthdayIcon,
                    what: 'birthdays',
                    shown: state.laterBirthdays,
                    onPressed: state.toggleLaterBirthdays,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FadeThrough(
              layoutBuilder: FadeThrough.fill,
              child: _LaterList(key: ValueKey(dateKey(day)), groups: groups, birthdays: birthdays, added: added),
            ),
          ),
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: DateTime(today.year, today.month, today.day + WeekCard.span + 1),
              birthdays: true,
              onAdd: (text, choice) => _addChosen(state, text, choice.day, choice),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day's further-ahead list: each date's tasks, then the repeats due
/// round on it; tasks without a day last.
class _LaterList extends StatefulWidget {
  const _LaterList({super.key, required this.groups, required this.birthdays, required this.added});

  final List<(DateTime?, List<_Later>)> groups;

  /// Whether birthdays show: shown or hidden, they pop in or out at once.
  final bool birthdays;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_LaterList> createState() => _LaterListState();
}

class _LaterListState extends State<_LaterList> with _DayMotion {
  /// Birthdays were just shown or hidden: this build jumps to how it is.
  var _instant = false;

  /// Birthday repeats just hidden, closing up where they were.
  final _hiding = <String, ({String group, int index, Repeat repeat})>{};

  static String _key(DateTime? date) => date == null ? 'none' : dateKey(date);

  /// A row by its day and task or repeat, so one that moves day counts as
  /// gone from where it was.
  static String _place(String group, _Later later) => '$group/${later.item?.id ?? later.repeat!.uid}';

  @override
  void didUpdateWidget(_LaterList old) {
    super.didUpdateWidget(old);
    // Birthdays shown or hidden pop in or out at once, as empty days do in
    // the week: the list is simply drawn as it now is.
    if (widget.birthdays != old.birthdays) {
      _instant = true;
      _drawn
        ..clear()
        ..addAll({
          for (final (date, items) in widget.groups) _key(date): [for (final later in items) ?later.item?.id],
        });
      return;
    }
    // Whatever's gone (ticked into Today or moved) closes up where it was.
    final now = {
      for (final (date, items) in widget.groups)
        for (final later in items) _place(_key(date), later),
    };
    for (final (date, items) in old.groups) {
      final group = _key(date);
      var repeats = 0;
      for (final later in items) {
        if (later.repeat != null) repeats++;
        if (now.contains(_place(group, later))) continue;
        if (later.item case final item?) {
          if (_departing.containsKey(item.id)) continue;
          _departing[item.id] = (
            group: group,
            index: (_drawn[group] ?? const []).indexOf(item.id),
            task: (later.scope!, item),
          );
          _after(() => _departing.remove(item.id));
        } else {
          final uid = later.repeat!.uid;
          _hiding[uid] = (group: group, index: repeats - 1, repeat: later.repeat!);
          _after(() => _hiding.remove(uid));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final instant = _instant;
    _instant = false;
    final p = context.palette;
    final state = AppScope.read(context);
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    final groups = [
      for (final (date, items) in widget.groups)
        (
          date: date,
          key: date == null ? 'none' : dateKey(date),
          tasks: [
            for (final later in items)
              if (later.item case final item?) (later.scope!, item),
          ],
          repeats: [for (final later in items) ?later.repeat],
        ),
    ];
    final current = {for (final g in groups) g.key};
    // A day whose last task was just removed stays while it closes up.
    for (final key in {
      for (final d in _departing.values) d.group,
      for (final h in _hiding.values) h.group,
    }.difference(current)) {
      groups.add((date: key == 'none' ? null : DateTime.parse(key), key: key, tasks: const [], repeats: <Repeat>[]));
    }
    for (final h in _hiding.values) {
      final repeats = groups.firstWhere((g) => g.key == h.group).repeats;
      if (!repeats.any((r) => r.uid == h.repeat.uid)) repeats.insert(h.index.clamp(0, repeats.length), h.repeat);
    }
    final hidden = _hiding.keys.toSet();
    groups.sort((a, b) => a.date == null ? 1 : (b.date == null ? -1 : a.date!.compareTo(b.date!)));
    final shown = {for (final g in groups) g.key: _shown(g.key, g.tasks)};
    _settle();
    if (groups.isEmpty) {
      return Center(
        child: Text(
          widget.birthdays || AppScope.read(context).viewDay != null
              ? 'Nothing more than a week away'
              : 'Nothing but birthdays',
          style: TextStyle(
            fontFamily: Fonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: p.inkMuted.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    return SmoothTaskScroll(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        scrollCacheExtent: const ScrollCacheExtent.pixels(80),
        slivers: [
          for (final (i, g) in groups.indexed)
            SliverPadding(
              key: ValueKey(g.key),
              padding: const EdgeInsets.only(right: 8),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    // A day comes and goes with its last tasks.
                    child: Appear(
                      animate: false,
                      shown: current.contains(g.key),
                      child: _DayHeading(
                        instant: instant,
                        first: i == 0,
                        parts: switch (g.date) {
                          null => const [('No date', true)],
                          final date => [
                            (_shortDate(date, state.today), true),
                            (weekdayNames[date.weekday - 1], false),
                          ],
                        },
                      ),
                    ),
                  ),
                  LazyTaskSliver(
                    ids: [
                      for (final s in shown[g.key]!) (s.task.$1, s.task.$2.id),
                      for (final repeat in g.repeats) repeat.uid,
                    ],
                    itemBuilder: (context, index) {
                      final tasks = shown[g.key]!;
                      if (index >= tasks.length) {
                        final repeat = g.repeats[index - tasks.length];
                        final (fadeIn, leaving) = (false, hidden.contains(repeat.uid));
                        if (repeat.birthday) {
                          return _LaterRow(day: day, repeat: repeat, date: g.date, fadeIn: fadeIn, leaving: leaving);
                        }
                        // Ticked like any other task, it's made first, then
                        // closes up here as it goes to Today: ticked.
                        final date = g.date!;
                        final made = leaving ? _made(state, '${repeat.uid}@${dateKey(date)}') : null;
                        TodoItem make() => state.occurrence(repeat, date);
                        return TaskRow(
                          key: ValueKey(repeat.uid),
                          scope: TodoScope.month,
                          item: made ?? _unmade(repeat, date),
                          day: day,
                          readOnly: readOnly,
                          fadeIn: fadeIn,
                          leaving: leaving,
                          make: made == null ? make : null,
                          onRemove: () => state.removeTodo(TodoScope.month, make()),
                        );
                      }
                      final (:task, :arriving, :leaving) = tasks[index];
                      final (scope, item) = task;
                      final fadeIn = widget.added.contains(item.id) || arriving;
                      void remove() => _remove(g.key, task, () => state.removeTodo(scope, item, day: day));
                      if (item.birthday) {
                        return _LaterRow(
                          key: ValueKey((scope, item.id)),
                          day: day,
                          task: task,
                          readOnly: readOnly,
                          fadeIn: fadeIn,
                          leaving: leaving,
                          onRemove: remove,
                        );
                      }
                      // Leaving because it was ticked, it closes up ticked.
                      final latest = leaving ? _latest(state, item) : null;
                      return TaskRow(
                        key: ValueKey((scope, item.id)),
                        scope: latest?.$1 ?? scope,
                        item: latest?.$2 ?? item,
                        day: day,
                        readOnly: readOnly,
                        fadeIn: fadeIn,
                        leaving: leaving,
                        onRemove: remove,
                        order: _order(g.key),
                      );
                    },
                  ),
                ],
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
        ],
      ),
    );
  }
}

/// [repeat]'s to-do for [date], before it's made.
TodoItem _unmade(Repeat repeat, DateTime date) => TodoItem(
  -1,
  repeat.text,
  since: date,
  dueDate: date,
  dueTime: repeat.time,
  birthday: repeat.birthday,
  reminders: repeat.reminders,
  uid: '${repeat.uid}@${dateKey(date)}',
);

/// The to-do made with [uid], wherever it is now.
TodoItem? _made(AppState state, String uid) =>
    [for (final items in state.todos.values) ...items].where((item) => item.uid == uid).firstOrNull;

/// [item] as it is now, and the list it's in, if it's still in one.
_Task? _latest(AppState state, TodoItem item) => [
  for (final MapEntry(key: scope, value: items) in state.todos.entries)
    for (final task in items) (scope, task),
].where((t) => t.$2.id == item.id).firstOrNull;

/// A birthday further ahead: a [task], or the next time a [repeat] comes round
/// on [date] before it's made. Either is only looked at from here, to
/// change or take away; it's ticked once it's in the week.
class _LaterRow extends StatefulWidget {
  const _LaterRow({
    super.key,
    required this.day,
    this.task,
    this.repeat,
    this.date,
    this.readOnly = false,
    this.fadeIn = false,
    this.leaving = false,
    this.onRemove,
  }) : assert(task != null || (repeat != null && date != null));

  /// The day the list is for.
  final DateTime day;
  final _Task? task;
  final Repeat? repeat;
  final DateTime? date;
  final bool readOnly;

  /// Fades in: just added.
  final bool fadeIn;

  /// Removed, closing up.
  final bool leaving;
  final VoidCallback? onRemove;

  @override
  State<_LaterRow> createState() => _LaterRowState();
}

class _LaterRowState extends State<_LaterRow> {
  bool _hover = false;

  /// The to-do, or the one the repeat will make, not made until it's
  /// changed on its own.
  TodoItem get _item => widget.task?.$2 ?? _unmade(widget.repeat!, widget.date!);

  TodoItem _make() => AppScope.read(context).occurrence(widget.repeat!, widget.date!);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    final item = _item;
    final repeat = widget.repeat ?? state.repeatOf(item);
    final scope = widget.task?.$1 ?? TodoScope.month;
    final made = widget.task != null;
    final caption = switch (repeat) {
      // A birthday's icon says it comes round every year.
      _? when item.birthday => null,
      final repeat? => repeat.rule.label,
      null when item.subtasks.isNotEmpty =>
        '${item.subtasks.where((child) => child.done).length}/${item.subtasks.length} complete',
      null => null,
    };
    return Appear(
      animate: widget.fadeIn,
      shown: !widget.leaving,
      child: IgnorePointer(
        ignoring: widget.readOnly || widget.leaving,
        child: Padding(
          padding: const EdgeInsets.only(left: 18, top: 2, bottom: 2),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: HoverFill(
              hover: _hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      child: repeat == null
                          ? null
                          : Icon(
                              item.birthday ? _birthdayIcon : Icons.repeat_rounded,
                              size: 16,
                              color: p.inkMuted.withValues(alpha: 0.8),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                if (item.dueTime case final time?)
                                  TextSpan(text: '${clockLabel(time)}  ', style: _timeStyle(p).copyWith(height: 1.35)),
                                TextSpan(text: item.text),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: Fonts.body,
                              fontSize: 15,
                              height: 1.35,
                              color: item.done
                                  ? p.inkMuted.withValues(alpha: p.brightness == Brightness.dark ? 0.75 : 0.7)
                                  : p.ink,
                              decoration: item.done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          if (caption != null)
                            Text(
                              caption,
                              style: TextStyle(fontFamily: Fonts.body, fontSize: 12, color: p.inkMuted),
                            ),
                        ],
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: _hover ? 1 : 0,
                      duration: Motion.hover,
                      curve: Motion.hoverCurve,
                      child: IgnorePointer(
                        ignoring: !_hover,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _TaskAction(
                              tooltip: 'Edit task',
                              icon: Icons.edit_rounded,
                              onPressed: () => _editTask(context, scope, item, widget.day, make: made ? null : _make),
                            ),
                            _TaskAction(
                              tooltip: 'Remove',
                              icon: Icons.close_rounded,
                              onPressed: () => _removeTask(
                                context,
                                item,
                                widget.day,
                                made ? widget.onRemove! : () => state.removeTodo(TodoScope.month, _make()),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
