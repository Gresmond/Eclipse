part of 'todo_panel.dart';

/// Today and the six days after it, one day under another: today always,
/// the others only when something's due. The strip of days at the top
/// jumps to one, follows the scroll, and takes a task dropped on it.
class WeekCard extends StatefulWidget {
  const WeekCard({super.key});

  /// The days after today it reaches; anything later is further ahead.
  static const span = 6;

  @override
  State<WeekCard> createState() => _WeekCardState();
}

class _WeekCardState extends State<WeekCard> with _NewTasks {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.shownDay, s.viewDay, s.weekEmptyDays));
    final day = state.shownDay;
    final past = state.viewDay != null;
    final planned = _Planned(state, day, past: past);
    final tasks = planned.days.expand((d) => d);
    final open = tasks.where((t) => !t.$2.done).length;
    final added = _added(day, [for (final (_, item) in tasks) item.id]);
    final today = state.today;

    return Tile(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TileHeader(
              title: 'Week ahead',
              caption: open == 0 && tasks.isNotEmpty ? 'All clear' : '$open open',
              trailingAtEnd: true,
              trailing: _ShowToggle(
                icon: Icons.date_range_rounded,
                what: 'days with no tasks',
                shown: state.weekEmptyDays,
                onPressed: state.toggleWeekEmptyDays,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Another day's week fades through as a whole.
          Expanded(
            child: FadeThrough(
              layoutBuilder: FadeThrough.fill,
              child: _WeekList(
                key: ValueKey(dateKey(day)),
                planned: planned,
                emptyDays: state.weekEmptyDays,
                added: added,
              ),
            ),
          ),
          _FoldAway(
            folded: past,
            child: _DatedAdd(
              first: today,
              last: DateTime(today.year, today.month, today.day + WeekCard.span),
              onAdd: (text, choice) => _addChosen(state, text, choice.day, choice),
            ),
          ),
        ],
      ),
    );
  }
}

/// One day's week: the days' lists, with [emptyDays] those with none.
class _WeekList extends StatefulWidget {
  const _WeekList({super.key, required this.planned, required this.emptyDays, required this.added});

  final _Planned planned;
  final bool emptyDays;

  /// Tasks just added, which fade in.
  final Set<int> added;

  @override
  State<_WeekList> createState() => _WeekListState();
}

class _WeekListState extends State<_WeekList> with _DayMotion {
  /// Whether a task is being dragged over each day, to light it.
  final _over = List.generate(WeekCard.span + 1, (_) => ValueNotifier(false));
  final _overBy = List.generate(WeekCard.span + 1, (_) => <Object>{});

  @override
  void dispose() {
    for (final over in _over) {
      over.dispose();
    }
    super.dispose();
  }

  DateTime _date(int i) {
    final day = AppScope.read(context).shownDay;
    return DateTime(day.year, day.month, day.day + i);
  }

  /// An open task of today's lists, not already on day [i], moves there.
  bool _accepts(_TaskDrag drag, int i) {
    final state = AppScope.read(context);
    return state.viewDay == null &&
        drag.day == state.today &&
        !drag.item.done &&
        !widget.planned.days[i].any((t) => t.$2.id == drag.item.id);
  }

  void _drop(_TaskDrag drag, int i) => AppScope.read(context).moveTodoTo(drag.scope, drag.item, _date(i));

  void _hover(int i, Object by, bool over) {
    over ? _overBy[i].add(by) : _overBy[i].remove(by);
    _over[i].value = _overBy[i].isNotEmpty;
  }

  /// [child], part of day [i], taking a task dropped on it for that day.
  Widget _dropTarget(int i, Widget child) {
    final by = Object();
    return DragTarget<_TaskDrag>(
      onWillAcceptWithDetails: (details) {
        final ok = _accepts(details.data, i);
        if (ok) _hover(i, by, true);
        return ok;
      },
      onLeave: (_) => _hover(i, by, false),
      onAcceptWithDetails: (details) {
        _hover(i, by, false);
        _drop(details.data, i);
      },
      builder: (context, candidates, rejected) => child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final day = state.shownDay;
    final readOnly = !state.canEditDay(day);
    final planned = widget.planned;
    final shown = [for (var i = 0; i <= WeekCard.span; i++) _shown('$i', planned.days[i])];
    _settle();
    // Today always; another day while it has tasks, or one closing up,
    // unless empty days show too.
    final visible = [
      for (var i = 0; i <= WeekCard.span; i++)
        if (i == 0 || widget.emptyDays || planned.days[i].isNotEmpty || _hasDeparting('$i')) i,
    ];
    return SmoothTaskScroll(
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        scrollCacheExtent: const ScrollCacheExtent.pixels(80),
        slivers: [
          for (final i in visible) _section(state, i, shown[i], readOnly, first: i == visible.first),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _section(AppState state, int i, List<_Shown> shown, bool readOnly, {required bool first}) {
    final p = context.palette;
    final date = _date(i);
    final added = widget.added;
    final weekday = weekdayNames[date.weekday - 1];
    final name = switch (daysBetween(state.today, date)) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    final Widget? foot;
    if (state.viewDay == null) {
      foot = _AddTask(day: date, today: state.today);
    } else if (!readOnly && i <= 1) {
      // Yesterday, while it can still be edited, takes tasks into its own
      // Today and Tomorrow.
      foot = _AddTask(day: date, today: state.today, past: state.viewDay);
    } else if (shown.isEmpty) {
      foot = Padding(
        padding: const EdgeInsets.fromLTRB(26, 6, 0, 4),
        child: Text(
          'Nothing planned',
          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted.withValues(alpha: 0.7)),
        ),
      );
    } else {
      foot = null;
    }
    final group = SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _dropTarget(
            i,
            _DayHeading(
              parts: [
                (_shortDate(date, state.today), true),
                if (name != null) (name, i == 0),
                if (name != 'Today') (weekday, false),
              ],
              strong: i == 0,
              first: first,
            ),
          ),
        ),
        if (i == 0 && shown.isEmpty && state.viewDay == null)
          SliverToBoxAdapter(
            child: _dropTarget(
              i,
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 6, 0, 2),
                child: Text(
                  'Nothing due',
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ),
        LazyTaskSliver(
          ids: [for (final s in shown) (s.task.$1, s.task.$2.id)],
          itemBuilder: (context, index) {
            final (:task, :arriving, :leaving) = shown[index];
            final (scope, item) = task;
            return _dropTarget(
              i,
              TaskRow(
                key: ValueKey((scope, item.id)),
                scope: scope,
                item: item,
                day: state.shownDay,
                readOnly: readOnly,
                fadeIn: added.contains(item.id) || arriving,
                arriving: arriving,
                leaving: leaving,
                onRemove: () => _remove('$i', task, () => state.removeTodo(scope, item, day: state.shownDay)),
              ),
            );
          },
        ),
        if (foot != null) SliverToBoxAdapter(child: _dropTarget(i, foot)),
      ],
    );
    // A day a task is dragged over lights up.
    return ValueListenableBuilder(
      valueListenable: _over[i],
      builder: (context, over, sliver) => TweenAnimationBuilder<double>(
        tween: Tween(end: over ? 0.08 : 0),
        duration: Motion.hover,
        curve: Motion.hoverCurve,
        builder: (context, alpha, sliver) => DecoratedSliver(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: p.accent.withValues(alpha: alpha),
          ),
          sliver: sliver!,
        ),
        child: sliver,
      ),
      child: SliverPadding(padding: const EdgeInsets.only(right: 8), sliver: group),
    );
  }
}

/// A day's heading, its parts joined with dots, over a rule.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.parts, this.strong = false, this.first = false, this.instant = false});

  /// The heading's parts; strong ones are full ink.
  final List<(String, bool)> parts;

  /// All in full ink: today's.
  final bool strong;

  /// The first in its list, with less room above.
  final bool first;

  /// Takes its room at once instead of easing to it.
  final bool instant;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Easing when a day comes in above it, or the one above goes.
    return AnimatedPadding(
      duration: instant ? Duration.zero : Motion.morph,
      curve: Motion.morphCurve,
      padding: EdgeInsets.only(top: first ? 12 : 22, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final (i, (part, full)) in parts.indexed) ...[
                  if (i > 0)
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: p.inkMuted.withValues(alpha: 0.5)),
                    ),
                  TextSpan(
                    text: part,
                    style: TextStyle(color: strong || full ? p.ink : p.inkMuted),
                  ),
                ],
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w700, color: p.ink),
          ),
          const SizedBox(height: 6),
          Container(height: 1, color: p.tileBorder.withValues(alpha: 0.6)),
        ],
      ),
    );
  }
}

/// Puts the cursor back in [focus]'s field with [selection] as it was.
/// Refocused from code, a desktop field would select all its text.
void _refocus(FocusNode focus, TextEditingController controller, TextSelection selection) {
  focus.requestFocus();
  // After the focus change, which is applied as a microtask.
  scheduleMicrotask(() {
    if (selection.isValid && selection.end <= controller.text.length) controller.selection = selection;
  });
}

/// [child] at a card's foot, folded away (while looking back) so it eases
/// out and back rather than snapping.
class _FoldAway extends StatelessWidget {
  const _FoldAway({required this.folded, required this.child});

  final bool folded;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedAlign(
      duration: Motion.morph,
      curve: Motion.morphCurve,
      alignment: Alignment.topCenter,
      heightFactor: folded ? 0 : 1,
      child: AnimatedOpacity(
        duration: Motion.morph,
        curve: Motion.morphCurve,
        opacity: folded ? 0 : 1,
        child: IgnorePointer(
          ignoring: folded,
          child: ExcludeFocus(excluding: folded, child: child),
        ),
      ),
    ),
  );
}
