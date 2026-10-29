import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';
import 'confirm_on_enter.dart';
import 'fade_menu.dart';
import 'fade_through.dart';
import 'rolling_number.dart';
import 'sleep_time.dart';

/// Shows a time, or [placeholder], and opens a [TimeWheel] to pick it.
/// Opening it with no time sets the one the wheel shows, [start]. The time
/// is set once the wheel closes, its changed digits rolling into place.
class TimePill extends StatefulWidget {
  const TimePill({
    super.key,
    required this.minutes,
    required this.start,
    required this.onChanged,
    this.title,
    this.placeholder = 'Select time',
    this.alignLeft = false,
  });

  final int? minutes;
  final int start;
  final ValueChanged<int> onChanged;
  final String? title;
  final String placeholder;

  /// Whether the wheel lines up with the pill's left edge, not its right.
  final bool alignLeft;

  @override
  State<TimePill> createState() => _TimePillState();
}

class _TimePillState extends State<TimePill> {
  bool _hover = false;

  Future<void> _open() async {
    int? picked;
    await showFadeMenu(
      context,
      width: 248,
      above: true,
      alignLeft: widget.alignLeft,
      builder: (_) => TimeWheel(
        title: widget.title,
        initial: widget.minutes ?? widget.start,
        unset: widget.minutes == null,
        onChanged: (minutes) => picked = minutes,
      ),
    );
    if (picked case final minutes? when minutes != widget.minutes) widget.onChanged(minutes);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final minutes = widget.minutes;
    final style = SleepName.timeStyle(p).copyWith(fontSize: 13, color: p.ink);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: AnimatedContainer(
          duration: Motion.hover,
          curve: Motion.hoverCurve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? p.empty : p.tile.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.tileBorder.withValues(alpha: 0.8)),
          ),
          child: FadeThrough(
            duration: Motion.click,
            child: minutes == null
                ? Text(
                    widget.placeholder,
                    key: const ValueKey(false),
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 13, color: p.inkMuted),
                  )
                // "9:05 pm", as a count's digits roll.
                : Semantics(
                    key: const ValueKey(true),
                    label: clockLabel(minutes),
                    excludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RollingNumber(value: (minutes ~/ 60 + 11) % 12 + 1, style: style),
                        Text(':', style: style),
                        RollingNumber(value: minutes % 60, digits: 2, style: style),
                        Text(' ', style: style),
                        FadeThrough(
                          duration: Motion.morph,
                          child: Text(minutes < 12 * 60 ? 'am' : 'pm', key: ValueKey(minutes < 12 * 60), style: style),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Three wheels, hour, minute (in fives) and am/pm, that set a time as
/// they turn. The hour and minute wheels go round and round.
class TimeWheel extends StatefulWidget {
  const TimeWheel({
    super.key,
    this.title,
    required this.initial,
    required this.onChanged,
    this.unset = false,
    this.onDone,
  });

  final String? title;

  /// Minutes from midnight; rounded to five.
  final int initial;

  /// Whether there's no time yet: opening sets [initial].
  final bool unset;

  final ValueChanged<int> onChanged;

  /// Leaves the wheel, on Enter; by default it closes the menu it's in.
  final VoidCallback? onDone;

  @override
  State<TimeWheel> createState() => _TimeWheelState();
}

class _TimeWheelState extends State<TimeWheel> {
  static const _row = 38.0;
  static const _rows = 5;

  late final int _start = (widget.initial / 5).round() * 5 % (24 * 60);
  late int _hour = _start ~/ 60 % 12, _minute = _start % 60 ~/ 5;
  late bool _pm = _start >= 12 * 60;

  // Started a few turns in, so the looping wheels can go either way.
  late final _hours = FixedExtentScrollController(initialItem: 12 * 50 + _hour);
  late final _minutes = FixedExtentScrollController(initialItem: 12 * 50 + _minute);
  late final _halves = FixedExtentScrollController(initialItem: _pm ? 1 : 0);

  @override
  void initState() {
    super.initState();
    if (widget.unset) WidgetsBinding.instance.addPostFrameCallback((_) => _save());
  }

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _halves.dispose();
    super.dispose();
  }

  void _save() => widget.onChanged((_hour + (_pm ? 12 : 0)) * 60 + _minute * 5);

  void _done() => (widget.onDone ?? Navigator.of(context).pop)();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = SleepName.timeStyle(p).copyWith(fontSize: 19, fontWeight: FontWeight.w600, color: p.ink);

    Widget wheel({
      required FixedExtentScrollController controller,
      required int count,
      required bool loop,
      required String Function(int) label,
      required int selected,
      required ValueChanged<int> onChanged,
      double width = 56,
    }) {
      Widget item(int i) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.animateToItem(
            // The nearest way round to it.
            loop
                ? controller.selectedItem + (i - controller.selectedItem % count + count ~/ 2) % count - count ~/ 2
                : i,
            duration: Motion.click,
            curve: Motion.clickCurve,
          ),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: Motion.hover,
              curve: Motion.hoverCurve,
              style: style.copyWith(color: i == selected ? p.ink : p.inkMuted.withValues(alpha: 0.75)),
              child: Text(label(i)),
            ),
          ),
        ),
      );
      return SizedBox(
        width: width,
        // A dragged wheel stops its rows taking the pointer, so their own
        // cursors drop out; this one keeps the hand while it turns.
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: _row,
            diameterRatio: 1.6,
            perspective: 0.004,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: (i) {
              onChanged(i % count);
              _save();
            },
            childDelegate: loop
                ? ListWheelChildLoopingListDelegate(children: [for (var i = 0; i < count; i++) item(i)])
                : ListWheelChildListDelegate(children: [for (var i = 0; i < count; i++) item(i)]),
          ),
        ),
      );
    }

    final title = widget.title;
    return ConfirmOnEnter(
      onConfirm: _done,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(
                title,
                style: TextStyle(fontFamily: Fonts.ui, fontSize: 13, fontWeight: FontWeight.w600, color: p.inkMuted),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              height: _row * _rows,
              // Rows fade out towards the wheel's top and bottom edges.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
                  stops: [0, 0.32, 0.68, 1],
                ).createShader(rect),
                // Dragged with the mouse as well as scrolled.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false, dragDevices: {...PointerDeviceKind.values}),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      wheel(
                        controller: _hours,
                        count: 12,
                        loop: true,
                        label: (i) => '${i == 0 ? 12 : i}',
                        selected: _hour,
                        onChanged: (i) => setState(() => _hour = i),
                      ),
                      Text(':', style: style),
                      wheel(
                        controller: _minutes,
                        count: 12,
                        loop: true,
                        label: (i) => (i * 5).toString().padLeft(2, '0'),
                        selected: _minute,
                        onChanged: (i) => setState(() => _minute = i),
                      ),
                      const SizedBox(width: 6),
                      wheel(
                        controller: _halves,
                        count: 2,
                        loop: false,
                        label: (i) => i == 0 ? 'am' : 'pm',
                        selected: _pm ? 1 : 0,
                        onChanged: (i) => setState(() => _pm = i == 1),
                        width: 52,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
