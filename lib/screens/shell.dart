import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../app_state.dart';
import '../data/backups.dart';
import '../data/updates.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../widgets/setting_rows.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/app_dialog.dart';
import '../widgets/fade_menu.dart';
import '../widgets/fade_through.dart';
import '../widgets/sync_banner.dart';
import '../widgets/update_banner.dart';
import '../widgets/welcome_tour.dart';
import 'month_view.dart';
import 'today_view.dart';
import 'year_view.dart';

/// Window chrome: title, year switcher and month tabs.
class Shell extends StatelessWidget {
  const Shell({super.key, this.updater});

  /// Null when the app has no supported installation metadata.
  final Updater? updater;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.navigation, s.touring));
    final month = state.viewMonth;

    final updater = this.updater;
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
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: state.viewingYear
                ? YearView(key: ValueKey('year ${state.viewYear}'), year: state.viewYear)
                : month == null
                ? const TodayView(key: ValueKey('today'))
                : MonthView(key: const ValueKey('month'), year: state.viewYear, month: month),
          ),
        ),
      ],
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: page),
          Positioned(
            right: 32,
            bottom: 28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (state.sync != null) SyncBanner(sync: state.sync!),
                if (updater != null)
                  ListenableBuilder(
                    listenable: updater,
                    builder: (context, _) => updater.status == UpdateStatus.none
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: UpdateBanner(updater: updater),
                          ),
                  ),
              ],
            ),
          ),
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

    final todayTitle = '${shown.day} ${monthNames[shown.month - 1]}';
    // After midnight but before the day starts, say so: the date shown is
    // the day you're still finishing.
    final weekday = weekdayNames[shown.weekday - 1];
    final (String kicker, String title) = state.viewingYear
        ? (state.viewYear == today.year ? 'Year to date' : 'The whole year', '${state.viewYear}')
        : month == null
        ? (
            state.viewDay != null
                ? '$weekday  ·  ${shown.year != today.year ? '${shown.year}  ·  ' : ''}${shown == DateTime(today.year, today.month, today.day - 1) ? 'yesterday' : 'looking back'}'
                : state.lateNight
                ? '$weekday  ·  until ${hourLabel(state.dayStartHour)}'
                : weekday,
            todayTitle,
          )
        : ('${state.viewYear}', monthNames[month - 1]);
    final titleStyle = TextStyle(
      fontFamily: Fonts.display,
      fontSize: 38,
      fontWeight: FontWeight.w600,
      letterSpacing: -1.3,
      height: 1.05,
      color: p.ink,
    );

    return Padding(
      // On macOS the window buttons float over the top of the content.
      padding: EdgeInsets.fromLTRB(32, Platform.isMacOS ? 27 : 15, 32, 11),
      child: Row(
        children: [
          // Fit the visible date, easing the right edge as its length changes.
          TourTarget(
            spot: TourSpot.date,
            child: _DateButton(
              enabled: month == null && !state.viewingYear,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: p.tile.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
                ),
                child: AnimatedSize(
                  duration: Motion.morph,
                  curve: Motion.morphCurve,
                  alignment: Alignment.centerLeft,
                  // Fades with the page below it, rather than snapping first.
                  child: FadeThrough(
                    layoutBuilder: (current, previous) => Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.topLeft,
                      children: [
                        // Outgoing text fades without holding the old width.
                        for (final child in previous) Positioned(left: 0, top: 0, child: child),
                        ?current,
                      ],
                    ),
                    // Tooltip enablement belongs to each fading label, so it
                    // cannot remount the pill's size or fade animations.
                    child: Tooltip(
                      key: ValueKey((kicker, title)),
                      message: month == null && !state.viewingYear ? 'Look back at another day' : '',
                      waitDuration: const Duration(milliseconds: 600),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            kicker.toUpperCase(),
                            style: TextStyle(
                              fontFamily: Fonts.ui,
                              fontSize: 11,
                              letterSpacing: 2.2,
                              fontWeight: FontWeight.w700,
                              color: p.inkMuted.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(title, style: titleStyle),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // Takes all the free space (a Spacer beside a Flexible would halve
          // it), right-aligned, scrolling only when the window is too narrow.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: TourTarget(
                spot: TourSpot.tabs,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: p.tile.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      child: _TabBar(
                        selected: state.viewDay != null
                            ? -1
                            : state.viewingYear
                            ? 13
                            : month ?? 0,
                        past: state.viewDay == null
                            ? null
                            : shown == DateTime(today.year, today.month, today.day - 1)
                            ? 'Yesterday'
                            : '${shown.day} ${monthNames[shown.month - 1].substring(0, 3)}'
                                  '${shown.year != today.year ? ' ${shown.year}' : ''}',
                        tabs: [
                          _Tab(
                            label: 'Today',
                            selected: month == null && !state.viewingYear && state.viewDay == null,
                            onTap: state.showToday,
                          ),
                          for (var m = 1; m <= 12; m++)
                            _Tab(
                              label: monthNames[m - 1].substring(0, 3),
                              selected: month == m,
                              isCurrent: state.viewYear == today.year && m == today.month,
                              future: DateTime(state.viewYear, m).isAfter(today),
                              onTap: () => state.showMonth(m),
                            ),
                          _Tab(label: 'Year', selected: state.viewingYear, onTap: state.showYear),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          _YearSwitcher(year: state.viewYear),
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
          ? () => showFadeMenu(context, alignLeft: true, width: 312, builder: (_) => const _DayPicker())
          : null,
      child: child,
    ),
  );
}

/// A month of days to pick from. Days after today can't be picked; picking
/// today goes back to it.
class _DayPicker extends StatefulWidget {
  const _DayPicker();

  @override
  State<_DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<_DayPicker> {
  late DateTime _month = DateTime(AppScope.of(context).shownDay.year, AppScope.of(context).shownDay.month);

  void _shift(int delta) => setState(() => _month = DateTime(_month.year, _month.month + delta));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.of(context);
    final today = state.today, shown = state.shownDay;
    final atToday = _month.year == today.year && _month.month == today.month;
    final lead = _month.weekday - 1; // Monday first
    final days = daysInMonth(_month.year, _month.month);

    Widget arrow(IconData icon, VoidCallback? onTap) => IconButton(
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: p.inkMuted,
      disabledColor: p.inkMuted.withValues(alpha: 0.25),
      onPressed: onTap,
      icon: Icon(icon),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${monthNames[_month.month - 1]} ${_month.year}',
                  style: TextStyle(fontFamily: Fonts.ui, fontSize: 14, fontWeight: FontWeight.w600, color: p.ink),
                ),
              ),
              arrow(Icons.chevron_left_rounded, () => _shift(-1)),
              arrow(Icons.chevron_right_rounded, atToday ? null : () => _shift(1)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final name in weekdayNames)
                Expanded(
                  child: Center(
                    child: Text(
                      name[0],
                      style: TextStyle(
                        fontFamily: Fonts.ui,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        color: p.inkMuted.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var week = 0; week * 7 < lead + days; week++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final d = week * 7 + col - lead + 1;
                        if (d < 1 || d > days) return const SizedBox(height: 38);
                        final day = DateTime(_month.year, _month.month, d);
                        return _PickerDay(
                          day: d,
                          selected: day == shown,
                          isToday: day == today,
                          enabled: !day.isAfter(today),
                          onTap: () {
                            state.showDay(day);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PickerDay extends StatefulWidget {
  const _PickerDay({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.enabled,
    required this.onTap,
  });

  final int day;
  final bool selected, isToday, enabled;
  final VoidCallback onTap;

  @override
  State<_PickerDay> createState() => _PickerDayState();
}

class _PickerDayState extends State<_PickerDay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final fg = selected
        ? p.onAccent
        : !widget.enabled
        ? p.inkMuted.withValues(alpha: 0.3)
        : widget.isToday
        ? p.accent
        : p.ink;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: AnimatedContainer(
            duration: Motion.hover,
            curve: Motion.hoverCurve,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: selected ? LinearGradient(colors: p.gradient.skip(1).toList()) : null,
              color: selected ? null : (_hover && widget.enabled ? p.empty : p.empty.withValues(alpha: 0)),
              border: widget.isToday && !selected ? Border.all(color: p.accent.withValues(alpha: 0.5)) : null,
            ),
            child: Text(
              '${widget.day}',
              style: TextStyle(
                fontFamily: Fonts.ui,
                fontSize: 13,
                fontWeight: selected || widget.isToday ? FontWeight.w600 : FontWeight.w500,
                color: fg,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tabs in a row, with one highlight pill that glides to the selected
/// tab instead of each tab lighting up on its own.
class _TabBar extends StatefulWidget {
  const _TabBar({required this.tabs, required this.selected, this.past});

  /// Today first, then January to December, then the year.
  final List<Widget> tabs;

  /// Index into [tabs], or -1 for the [past] day's tab.
  final int selected;

  /// The past day being looked at, which opens a tab left of Today.
  final String? past;

  @override
  State<_TabBar> createState() => _TabBarState();
}

class _TabBarState extends State<_TabBar> with TickerProviderStateMixin {
  final _stackKey = GlobalKey();
  final _pastKey = GlobalKey();
  late final _keys = [for (final _ in widget.tabs) GlobalKey()];

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

  /// From the bar's right edge, which stays put as the past tab folds.
  ({double right, double top, Size size})? _pill;
  int? _pillFor;
  bool _glide = false;

  @override
  void didUpdateWidget(_TabBar old) {
    super.didUpdateWidget(old);
    if (widget.past != null) {
      _fold?.cancel();
      if (old.past != null && old.past != widget.past) {
        _fromWidth = _labelWidth;
        _toWidth = _Tab.boldWidth(context, widget.past!);
        _relabel.forward(from: 0);
      }
      _pastLabel = widget.past;
      _pastOpen.forward();
    } else if (old.past != null) {
      _fold = Timer(Motion.morph, () {
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

  /// Moves the pill under the selected tab once it has been laid out.
  /// Only a change of tab glides; resizing the window just follows along.
  void _measure(Duration _) {
    // A changing label drives the pill itself, frame by frame.
    if (!mounted || _relabel.isAnimating) return;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final key = widget.selected < 0 ? _pastKey : _keys[widget.selected];
    final tab = key.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || tab == null || !tab.hasSize || !stack.hasSize) return;
    // Measured from the right, so a tab still unfolding is placed where it
    // ends up.
    final at = tab.localToGlobal(Offset.zero, ancestor: stack);
    final rect = (right: stack.size.width - at.dx - tab.size.width, top: at.dy, size: tab.size);
    if (rect == _pill) return;
    setState(() {
      _glide = _pillFor != null && _pillFor != widget.selected;
      _pillFor = widget.selected;
      _pill = rect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    final pill = _pill;
    final divider = Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: p.tileBorder.withValues(alpha: 0.8),
    );

    return AnimatedBuilder(animation: _relabel, builder: (context, _) => _bar(p, pill, divider));
  }

  Widget _bar(Palette p, ({double right, double top, Size size})? pill, Widget divider) {
    final labelWidth = _labelWidth;
    final relabeling = _relabel.isAnimating && widget.selected < 0;
    return Stack(
      key: _stackKey,
      children: [
        if (pill != null)
          AnimatedPositioned(
            duration: _glide && !relabeling ? Motion.morph : Duration.zero,
            curve: Motion.morphCurve,
            right: pill.right,
            top: pill.top,
            width: relabeling ? labelWidth + _Tab.padding * 2 : pill.size.width,
            height: pill.size.height,
            // A rounded rect, not a StadiumBorder: Impeller on Linux draws
            // shape paths without anti-aliasing, but rounded rects smoothly.
            child: DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(30), color: p.done),
            ),
          ),
        Row(
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
                    child: Opacity(opacity: t, child: child),
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
                            selected: widget.selected < 0,
                            onTap: null,
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
              KeyedSubtree(key: _keys[i], child: tab),
              const SizedBox(width: 2),
              // Today and Year stand apart from the months.
              if (i == 0 || i == widget.tabs.length - 2) divider,
            ],
          ],
        ),
      ],
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.isCurrent = false,
    this.future = false,
    this.labelWidth,
  });

  static const padding = 14.0;

  /// The width a label takes in bold, which a tab keeps whether or not it
  /// is selected.
  static double boldWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _style(FontWeight.w600, const Color(0xFF000000))),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  static TextStyle _style(FontWeight weight, Color color) =>
      TextStyle(fontFamily: Fonts.ui, fontSize: 12.5, fontWeight: weight, color: color, letterSpacing: 0.2);

  /// Set for a tab whose label changes: the label area eases to this width
  /// while the old label fades through to the new one.
  final double? labelWidth;

  final String label;
  final bool selected;
  final bool isCurrent;
  final bool future;

  /// Null for a tab that only shows where you are.
  final VoidCallback? onTap;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final fg = selected
        ? p.onAccent
        : widget.isCurrent
        ? p.accent
        : widget.future
        ? p.inkMuted.withValues(alpha: 0.4)
        : p.ink;
    TextStyle style(FontWeight weight) => _Tab._style(weight, fg);
    final label = Stack(
      alignment: Alignment.center,
      children: [
        // Reserves the bold width, so selecting a tab never resizes the bar.
        Visibility.maintain(visible: false, child: Text(widget.label, style: style(FontWeight.w600))),
        AnimatedDefaultTextStyle(
          duration: Motion.morph,
          curve: Motion.morphCurve,
          style: style(selected || widget.isCurrent ? FontWeight.w600 : FontWeight.w500),
          child: Text(widget.label),
        ),
      ],
    );
    final width = widget.labelWidth;

    // The selected background is the bar's gliding pill; a tab only draws
    // its hover shade, and its text colour eases as the pill arrives.
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: _Tab.padding, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: !selected && _hover ? p.empty : p.empty.withValues(alpha: 0),
          ),
          child: width == null
              ? label
              : SizedBox(
                  width: width,
                  child: OverflowBox(
                    maxWidth: double.infinity,
                    fit: OverflowBoxFit.deferToChild,
                    child: FadeThrough(
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.center, children: [...previous, ?current]),
                      child: KeyedSubtree(key: ValueKey(widget.label), child: label),
                    ),
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
        border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          IconButton(
            iconSize: 18,
            color: p.inkMuted,
            onPressed: () => state.shiftYear(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Text(
            '$year',
            style: TextStyle(
              fontFamily: Fonts.ui,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: p.ink,
              letterSpacing: 0.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            iconSize: 18,
            color: p.inkMuted,
            onPressed: () => state.shiftYear(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

/// Opens Settings; confirms a restore once it's done.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  Future<void> _open(BuildContext context) async {
    final p = context.palette;
    final restored = await showAppDialog<Backup>(context: context, builder: (_) => const SettingsDialog());
    if (restored == null || !context.mounted) return;
    final from = restored.isBeforeRestore
        ? 'how things were before your last restore'
        : restored.isBeforeJoin
        ? 'how things were before joining sync'
        : '${restored.day!.day} ${monthNames[restored.day!.month - 1]}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 520,
        backgroundColor: p.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(
          'Restored $from. What you had before is saved as a backup too.',
          style: TextStyle(fontFamily: Fonts.ui, fontSize: 13.5, color: p.tile),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: 'Settings',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => _open(context),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: p.tile.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
            ),
            child: Icon(Icons.settings_rounded, size: 21, color: p.inkMuted),
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
    return Tooltip(
      message: 'Appearance',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => showFadeMenu(context, builder: (_) => const _AppearanceMenu()),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: p.tile.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              border: Border.all(color: p.tileBorder.withValues(alpha: 0.85)),
            ),
            child: _Swatch(palette: p, size: 36),
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
                      fontSize: 14,
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
                    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2.5)),
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
            title: Platform.isMacOS ? 'Follow Dark mode' : 'Follow the sun',
            subtitle: Platform.isMacOS
                ? 'Its dark partner while macOS is in Dark mode.'
                : "Switch to your theme's dark partner when the sun goes down.",
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
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: palette.tile, width: size * 0.08),
        gradient: SweepGradient(colors: [...palette.gradient, palette.gradient.first]),
      ),
    );
  }
}
