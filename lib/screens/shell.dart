import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../app_state.dart';
import '../data/backups.dart';
import '../data/updates.dart';
import '../models.dart';
import '../theme/pixels.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/setting_rows.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/app_dialog.dart';
import '../widgets/backup_card.dart';
import '../widgets/day_picker.dart';
import '../widgets/fade_menu.dart';
import '../widgets/fade_through.dart';
import '../widgets/fold.dart';
import '../widgets/glide_pill.dart';
import '../widgets/hover_fill.dart';
import '../widgets/reminder_cards.dart';
import '../widgets/search_dialog.dart';
import '../widgets/smooth_gradient.dart';
import '../widgets/sync_banner.dart';
import '../widgets/update_banner.dart';
import '../widgets/welcome_tour.dart';
import 'month_view.dart';
import 'today_view.dart';
import 'warm_up.dart';
import 'training_view.dart';
import 'year_view.dart';

/// The corner cards over the window and its dialogs: backups, sync, an update
/// and reminders, stacked above the undo card.
class CornerCards extends StatelessWidget {
  const CornerCards({super.key, this.updater});

  final Updater? updater;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.sync, s.backupProblem));
    final sync = state.sync;
    final updater = this.updater;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        BackupCard(
          problem: state.backupProblem,
          // Above the navigator here, so it opens from the navigator's context.
          onSeeBackups: () {
            if (appNavigator.currentContext case final context?) openSettings(context, ribbon: 1);
          },
        ),
        const RestoredCard(),
        if (sync != null) SyncBanner(sync: sync),
        if (updater != null) UpdateBanner(updater: updater),
        const ReminderCards(),
      ],
    );
  }
}

/// Window chrome: title, year switcher and month tabs.
class Shell extends StatelessWidget {
  const Shell({super.key, this.updater});

  /// Null when the app has no supported installation metadata.
  final Updater? updater;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.navigation, s.touring));
    final month = state.viewMonth;

    final hasWideGrid = kIsWeb && !state.showingTraining && (state.viewingYear || month != null);
    final narrowGrid = hasWideGrid && MediaQuery.sizeOf(context).width < 850;
    final content = state.showingTraining
        ? const TrainingView(key: ValueKey('training'))
        : state.viewingYear
        ? YearView(key: const ValueKey('year'), year: state.viewYear)
        : month == null
        ? const TodayView(key: ValueKey('today'))
        : MonthView(key: const ValueKey('month'), year: state.viewYear, month: month);
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(),
        Expanded(
          // Months share one MonthView, whose grid morphs in place, so the
          // card stays put when you move between months. Days share one
          // TodayView the same way: only what differs fades or eases.
          child: FadeThrough(
            deferBuild: true,
            layoutBuilder: FadeThrough.fill,
            child: hasWideGrid
                ? LayoutBuilder(
                    key: ValueKey(state.viewingYear ? 'year-grid' : 'month-grid'),
                    builder: (context, box) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: narrowGrid ? null : const NeverScrollableScrollPhysics(),
                      child: SizedBox(width: narrowGrid ? 850 : box.maxWidth, height: box.maxHeight, child: content),
                    ),
                  )
                : content,
          ),
        ),
      ],
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: context.palette.background, child: page),
          ),
          if (WarmUp.enabled) const Positioned.fill(child: WarmUp()),
          if (state.touring) Positioned.fill(child: WelcomeTour(appearanceBuilder: (_) => const _AppearanceMenu())),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => s.navigation);
    final today = state.today;
    final month = state.viewMonth;
    final shown = state.shownDay;
    final months = state.shownMonths(state.viewYear);

    final todayTitle = '${shown.day} ${monthNames[shown.month - 1]}';
    // After midnight but before the day starts, say so: the date shown is
    // the day you're still finishing.
    final weekday = weekdayNames[shown.weekday - 1];
    // Today's holiday, on the day, month and year alike; not looking back.
    final holiday = switch (holidayOn(state.holidays, today)) {
      final h? when state.viewDay == null => '  ·  on holiday until ${shortDay(h.end, today: today)}',
      _ => '',
    };
    // Training opens over the view you were on.
    final elsewhere = state.showingTraining;
    final onDay = month == null && !state.viewingYear && !elsewhere;
    final (String kicker, String title) = state.showingTraining
        ? ('Progress', 'Training')
        : state.viewingYear
        ? ('${state.viewYear == today.year ? 'Year to date' : 'The whole year'}$holiday', '${state.viewYear}')
        : month == null
        ? (
            state.viewDay != null
                ? '$weekday  ·  ${shown.year != today.year ? '${shown.year}  ·  ' : ''}${shown == DateTime(today.year, today.month, today.day - 1) ? 'yesterday' : 'looking back'}'
                : state.lateNight
                ? '$weekday  ·  until ${hourLabel(state.dayStartHour)}$holiday'
                : '$weekday$holiday',
            todayTitle,
          )
        : ('${state.viewYear}$holiday', monthNames[month - 1]);
    if (kIsWeb && MediaQuery.sizeOf(context).width < 850) {
      return SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(
            children: [
              Expanded(
                child: PopupMenuButton<VoidCallback>(
                  tooltip: 'Change view',
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: state.showToday, child: const Text('Today')),
                    for (final m in months)
                      PopupMenuItem(value: () => state.showMonth(m), child: Text(monthNames[m - 1])),
                    PopupMenuItem(value: state.showYear, child: const Text('Year')),
                    PopupMenuItem(
                      value: () {
                        if (!state.showingTraining) state.toggleTraining();
                      },
                      child: const Text('Training'),
                    ),
                    if (!elsewhere && (state.viewYear > state.firstMonth.$1 || state.viewYear < today.year)) ...[
                      const PopupMenuDivider(),
                      if (state.viewYear > state.firstMonth.$1)
                        PopupMenuItem(
                          value: () => state.shiftYear(-1),
                          child: Text('Previous year (${state.viewYear - 1})'),
                        ),
                      if (state.viewYear < today.year)
                        PopupMenuItem(
                          value: () => state.shiftYear(1),
                          child: Text('Next year (${state.viewYear + 1})'),
                        ),
                    ],
                  ],
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        kicker.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: capsLabel(p.inkMuted),
                      ),
                      trailing: const Icon(Icons.expand_more_rounded),
                    ),
                  ),
                ),
              ),
              if (onDay) ...[
                IconButton(
                  tooltip: 'Look back at another day',
                  icon: const Icon(Icons.calendar_today_rounded),
                  onPressed: () => showFadeMenu(
                    context,
                    alignLeft: true,
                    width: 312,
                    builder: (_) {
                      final (y, m) = state.firstMonth;
                      return DayPicker(
                        today: state.today,
                        first: DateTime(y, m),
                        selected: state.shownDay,
                        onPick: state.showDay,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
              ],
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded),
                onPressed: () => showAppDialog<void>(context: context, builder: (_) => const SearchDialog()),
              ),
              const SizedBox(width: 10),
              const _SettingsButton(),
              const SizedBox(width: 10),
              const _ThemeButton(),
            ],
          ),
        ),
      );
    }
    final titleStyle = TextStyle(
      fontFamily: Fonts.display,
      fontSize: 38,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.6,
      height: 1.05,
      color: p.ink,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 15, 32, 11),
      child: PixelRow(
        children: [
          // Fit the visible date, easing the right edge as its length changes.
          TourTarget(
            spot: TourSpot.date,
            child: _DateButton(
              enabled: onDay,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                // A longer date's room opens before it fades in, and a shorter
                // one's closes only once the old has faded: never clipped.
                child: PageSize(
                  page: (kicker, title),
                  // Fades with the page below it, rather than snapping first.
                  child: FadeThrough(
                    // Outgoing text fades without holding the old width.
                    layoutBuilder: FadeThrough.pinTopLeft,
                    // Tooltip enablement belongs to each fading label, so it
                    // cannot remount the pill's size or fade animations.
                    child: PixelTooltip(
                      key: ValueKey((kicker, title)),
                      message: onDay ? 'Look back at another day' : '',
                      child: PixelFit(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ...[Text(kicker.toUpperCase(), style: capsLabel(p.inkMuted)), const SizedBox(height: 4)],
                            Text(title, style: titleStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Takes all the free space, right-aligned.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              // Scrolling only when the window is too narrow. Straight: a rounded
              // clip's edge is jagged under Impeller.
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  child: PixelRow(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _PageButtons(),
                      const SizedBox(width: 10),
                      TourTarget(
                        spot: TourSpot.tabs,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: p.tile.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(color: p.border),
                          ),
                          child: _TabBar(
                            selected: elsewhere
                                ? null
                                : state.viewDay != null
                                ? -1
                                : state.viewingYear
                                ? months.length + 1
                                : month == null
                                ? 0
                                : months.indexOf(month) + 1,
                            past: state.viewDay == null
                                ? null
                                : shown == DateTime(today.year, today.month, today.day - 1)
                                ? 'Yesterday'
                                : dayAndMonth(shown, today: today),
                            onPast: elsewhere ? state.closePages : null,
                            tabs: [
                              _Tab(label: 'Today', selected: onDay && state.viewDay == null, onTap: state.showToday),
                              for (final m in months)
                                _Tab(
                                  label: shortMonth(m),
                                  selected: !elsewhere && month == m,
                                  isCurrent: state.viewYear == today.year && m == today.month,
                                  onTap: () => state.showMonth(m),
                                ),
                              _Tab(label: 'Year', selected: !elsewhere && state.viewingYear, onTap: state.showYear),
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
          Fold(
            axis: Axis.horizontal,
            open: !elsewhere,
            removeWhenClosed: true,
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: _YearSwitcher(year: state.viewYear),
            ),
          ),
          const SizedBox(width: 10),
          const TourTarget(spot: TourSpot.settings, child: _SettingsButton()),
          const SizedBox(width: 10),
          const TourTarget(spot: TourSpot.appearance, child: _ThemeButton()),
        ],
      ),
    );
  }
}

/// The big date, which opens a calendar to look back at a past day.
class _DateButton extends StatelessWidget {
  const _DateButton({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () => showFadeMenu(
              context,
              alignLeft: true,
              width: 312,
              builder: (_) {
                final state = AppScope.read(context);
                final (y, m) = state.firstMonth;
                return DayPicker(
                  today: state.today,
                  first: DateTime(y, m),
                  selected: state.shownDay,
                  onPick: state.showDay,
                );
              },
            )
          : null,
      child: child,
    ),
  );
}

/// Training and search: their own pill, left of the tabs. A page opens over the
/// view you're on and, clicked again, goes back to it; search opens its dialog.
class _PageButtons extends StatefulWidget {
  const _PageButtons();

  @override
  State<_PageButtons> createState() => _PageButtonsState();
}

class _PageButtonsState extends State<_PageButtons> {
  final _training = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => s.showingTraining);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.tile.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: p.border),
      ),
      child: GlidePill(
        target: state.showingTraining ? _training : null,
        color: p.done,
        child: Row(
          children: [
            KeyedSubtree(
              key: _training,
              child: _IconTab(
                icon: Icons.fitness_center_rounded,
                tooltip: 'Training',
                selected: state.showingTraining,
                onTap: state.toggleTraining,
              ),
            ),
            const SizedBox(width: 2),
            _IconTab(
              icon: Icons.search_rounded,
              tooltip: 'Search',
              selected: false,
              onTap: () => showAppDialog<void>(context: context, builder: (_) => const SearchDialog()),
            ),
          ],
        ),
      ),
    );
  }
}

/// A [_Tab] with an icon for its label, the same height.
class _IconTab extends StatelessWidget {
  const _IconTab({required this.icon, required this.tooltip, required this.selected, required this.onTap});

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PixelTooltip(
      message: tooltip,
      child: Hoverable(
        focusable: true,
        semanticLabel: tooltip,
        onTap: onTap,
        builder: (hover) => AnimatedContainer(
          duration: context.themed(Motion.hover),
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: !selected && hover ? p.empty : p.empty.withValues(alpha: 0),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Nothing to see: holds a tab's text height, at any text size.
              Text('\u200b', style: _Tab._style(FontWeight.w600, p.ink)),
              TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: selected ? p.onDone : p.ink),
                duration: context.themed(Motion.morph),
                curve: Motion.morphCurve,
                builder: (context, colour, _) => Icon(icon, size: Scale.navIcon, color: colour),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tabs in a row, with one highlight pill that glides to the selected
/// tab instead of each tab lighting up on its own.
class _TabBar extends StatefulWidget {
  const _TabBar({required this.tabs, required this.selected, this.past, this.onPast});

  /// Today first, then the months shown, then the year.
  final List<Widget> tabs;

  /// Index into [tabs], or -1 for the [past] day's tab; null for none, while
  /// another page is open.
  final int? selected;

  /// The past day being looked at, which opens a tab left of Today.
  final String? past;

  /// Clicking the [past] day's tab, which otherwise only shows where you are.
  final VoidCallback? onPast;

  @override
  State<_TabBar> createState() => _TabBarState();
}

class _TabBarState extends State<_TabBar> with TickerProviderStateMixin {
  final _pastKey = GlobalKey();

  /// By position; the months shown change with the year.
  final _keys = <GlobalKey>[];
  GlobalKey _key(int i) {
    while (_keys.length <= i) {
      _keys.add(GlobalKey());
    }
    return _keys[i];
  }

  /// Unfolds the past day's tab; it folds only after the pill has left it.
  late final _pastOpen = AnimationController(vsync: this, duration: Motion.morph, value: widget.past == null ? 0 : 1);
  late String? _pastLabel = widget.past;
  Timer? _fold;

  /// Eases the past tab, and the pill under it, from one day's label width
  /// to the next while the labels fade through, like the big date.
  late final _relabel = AnimationController(vsync: this, duration: Motion.morph, value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
  double _fromWidth = 0, _toWidth = 0;

  double get _labelWidth => _relabel.isAnimating
      ? _fromWidth + (_toWidth - _fromWidth) * Motion.morphCurve.transform(_relabel.value)
      : _Tab.boldWidth(context, _pastLabel ?? '');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = context.themed(Motion.morph);
    _pastOpen.duration = duration;
    _relabel.duration = duration;
  }

  @override
  void didUpdateWidget(_TabBar old) {
    super.didUpdateWidget(old);
    if (widget.past != null) {
      _fold?.cancel();
      if (_pastOpen.value > 0 && _pastLabel != null && _pastLabel != widget.past) {
        _fromWidth = _labelWidth;
        _toWidth = _Tab.boldWidth(context, widget.past!);
        _relabel.forward(from: 0);
      } else if (_pastOpen.value == 0) {
        _relabel.value = 1;
      }
      _pastLabel = widget.past;
      _pastOpen.forward();
    } else if (old.past != null) {
      _fold = Timer(context.themed(Motion.morph), () {
        if (mounted) _pastOpen.reverse();
      });
    }
  }

  @override
  void dispose() {
    _fold?.cancel();
    _pastOpen.dispose();
    _relabel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final divider = Container(width: 1, height: 18, margin: const EdgeInsets.symmetric(horizontal: 6), color: p.border);

    return AnimatedBuilder(animation: _relabel, builder: (context, _) => _bar(p, divider));
  }

  Widget _bar(Palette p, Widget divider) {
    final labelWidth = _labelWidth;
    final selected = widget.selected;
    return GlidePill(
      target: selected == null
          ? null
          : selected < 0
          ? _pastKey
          : _key(selected),
      color: p.done,
      child: Row(
        children: [
          // Grows in from Today's left, its label easing into view.
          AnimatedBuilder(
            animation: _pastOpen,
            builder: (context, child) {
              final t = Motion.morphCurve.transform(_pastOpen.value);
              return ClipRect(
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: t,
                  child: IgnorePointer(
                    ignoring: t == 0,
                    child: ExcludeFocus(
                      excluding: t == 0,
                      child: ExcludeSemantics(
                        excluding: t == 0,
                        child: Opacity(opacity: t, child: child),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: _pastLabel == null
                ? const SizedBox.shrink()
                : Row(
                    children: [
                      KeyedSubtree(
                        key: _pastKey,
                        child: _Tab(
                          label: _pastLabel!,
                          selected: selected != null && selected < 0,
                          onTap: widget.onPast,
                          labelWidth: labelWidth,
                        ),
                      ),
                      const SizedBox(width: 2),
                      divider,
                    ],
                  ),
          ),
          for (final (i, tab) in widget.tabs.indexed) ...[
            // The gap sits outside the measured tab, so the pill centres on
            // the label.
            KeyedSubtree(key: _key(i), child: tab),
            const SizedBox(width: 2),
            // Today and Year stand apart from the months.
            if (i == 0 || i == widget.tabs.length - 2) divider,
          ],
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.isCurrent = false,
    this.labelWidth,
  });

  static const padding = 14.0;

  /// The width a label takes.
  static double boldWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _style(FontWeight.w600, const Color(0xFF000000))),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return pixelCeil(width);
  }

  static TextStyle _style(FontWeight weight, Color color) =>
      TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: weight, color: color);

  /// Set for a tab whose label changes: the label area eases to this width
  /// while the old label fades through to the new one.
  final double? labelWidth;

  final String label;
  final bool selected;
  final bool isCurrent;

  /// Null for a tab that only shows where you are.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = selected
        ? p.onDone
        : isCurrent
        ? p.accent
        : p.ink;
    // Semibold whether or not selected, as Settings' ribbons are: only the
    // colour eases as the pill arrives, so the bar never steps in weight.
    final text = AnimatedDefaultTextStyle(
      duration: context.themed(Motion.morph),
      curve: Motion.morphCurve,
      style: _style(FontWeight.w600, fg),
      child: Text(label),
    );
    final width = labelWidth;

    // The selected background is the bar's gliding pill; a tab only draws
    // its hover shade, and its text colour eases as the pill arrives.
    return Hoverable(
      focusable: onTap != null,
      semanticLabel: label,
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.hover),
        curve: Motion.hoverCurve,
        padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: !selected && hover ? p.empty : p.empty.withValues(alpha: 0),
        ),
        child: width == null
            ? PixelFit(child: text)
            : SizedBox(
                width: width,
                child: OverflowBox(
                  maxWidth: double.infinity,
                  fit: OverflowBoxFit.deferToChild,
                  child: FadeThrough(
                    child: KeyedSubtree(key: ValueKey(label), child: text),
                  ),
                ),
              ),
      ),
    );
  }
}

class _YearSwitcher extends StatelessWidget {
  const _YearSwitcher({required this.year});

  final int year;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.read(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: p.tile.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          if (year > state.firstMonth.$1)
            PixelTooltip(
              message: 'Previous year',
              child: IconButton(
                iconSize: Scale.navIcon,
                // 40 tall, so the pill matches the tabs and the round buttons.
                visualDensity: VisualDensity.compact,
                color: p.inkMuted,
                onPressed: () => state.shiftYear(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            )
          else
            // Holds the arrow's height, so the pill keeps its size.
            const SizedBox(width: 14, height: 40),
          Text(
            '$year',
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: p.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (year < state.today.year)
            PixelTooltip(
              message: 'Next year',
              child: IconButton(
                iconSize: Scale.navIcon,
                // 40 tall, so the pill matches the tabs and the round buttons.
                visualDensity: VisualDensity.compact,
                color: p.inkMuted,
                onPressed: () => state.shiftYear(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            )
          else
            // Holds the arrow's height, so the pill keeps its size.
            const SizedBox(width: 14, height: 40),
        ],
      ),
    );
  }
}

/// Opens Settings on [ribbon]; confirms a restore once it's done.
Future<void> openSettings(BuildContext context, {int ribbon = 0}) async {
  final restored = await showAppDialog<Backup>(
    context: context,
    builder: (_) => SettingsDialog(ribbon: ribbon),
  );
  if (restored == null || !context.mounted) return;
  final from = restored.isBeforeRestore
      ? 'how things were before your last restore'
      : restored.isBeforeJoin
      ? 'how things were before joining sync'
      : restored.isBeforeUpdate
      ? 'how things were before your last update'
      : '${restored.day!.day} ${monthNames[restored.day!.month - 1]}';
  AppScope.read(context).noteRestored(from);
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PixelTooltip(
      message: 'Settings',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => openSettings(context),
          child: Container(
            width: 46,
            height: 46,
            decoration: SmoothGradientDecoration(
              color: p.tile.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              border: Border.all(color: p.border),
            ),
            child: Icon(Icons.settings_rounded, size: 22, color: p.inkMuted),
          ),
        ),
      ),
    );
  }
}

/// Round swatch of the current theme; opens a menu of all themes and
/// whether to follow night light.
class _ThemeButton extends StatelessWidget {
  const _ThemeButton();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: 'Appearance',
      child: PixelTooltip(
        message: 'Appearance',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            mouseCursor: SystemMouseCursors.click,
            onTap: () => showFadeMenu(context, builder: (_) => const _AppearanceMenu()),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: SmoothGradientDecoration(
                color: p.tile.withValues(alpha: 0.8),
                shape: BoxShape.circle,
                border: Border.all(color: p.border),
              ),
              child: _Swatch(palette: p, size: 36),
            ),
          ),
        ),
      ),
    );
  }
}

/// The appearance menu's contents. Picking a theme closes it; the switch
/// flips in place, so you see it move.
class _AppearanceMenu extends StatelessWidget {
  const _AppearanceMenu();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in palettes)
          FadeMenuRow(
            height: 50,
            onTap: () {
              if (kIsWeb && state.followNightLight && option.brightness != p.brightness) {
                state.setFollowNightLight(false);
              }
              state.setTheme(option.name);
              Navigator.pop(context);
            },
            child: Row(
              children: [
                _Swatch(palette: option, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    option.name,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: 15,
                      fontWeight: option.name == p.name ? FontWeight.w600 : FontWeight.w500,
                      color: p.ink,
                    ),
                  ),
                ),
                for (final c in [option.done, option.missed, option.other, option.today])
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
                  ),
                SizedBox(
                  width: 32,
                  child: option.name == p.name ? Icon(Icons.check_rounded, size: 18, color: p.accent) : null,
                ),
              ],
            ),
          ),
        if (state.nightLightAvailable) ...[
          const FadeMenuDivider(),
          SettingSwitchRow(
            title: kIsWeb ? 'Follow system dark mode' : 'Follow the sun',
            subtitle: kIsWeb
                ? 'Switch to your theme’s dark partner when your browser prefers dark mode.'
                : 'Switch to your theme’s dark partner when Night Light is on.',
            on: state.followNightLight,
            onTap: () => state.setFollowNightLight(!state.followNightLight),
          ),
        ],
      ],
    );
  }
}

/// A theme's gradient as a disc, ringed by its tile colour.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.size});

  final Palette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: SmoothGradientDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: palette.tile, width: size * 0.08),
        gradient: SweepGradient(colors: [...palette.gradient, palette.gradient.first]),
      ),
    );
  }
}
