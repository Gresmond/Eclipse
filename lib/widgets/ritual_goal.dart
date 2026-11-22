import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'fold.dart';
import 'glide_pill.dart';
import 'hover_fill.dart';

Future<void> editRitualGoal(BuildContext context, Habit h, int year, int month) async {
  final state = AppScope.read(context);
  var weekly = h.weekly, lastWeekly = h.weekly ?? 3;
  var target = h.target?.toString() ?? '', unit = h.unit ?? '';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final p = ctx.palette;
        final trimmedTarget = target.trim();
        final parsedTarget = int.tryParse(trimmedTarget);
        final valid = trimmedTarget.isEmpty || (parsedTarget != null && parsedTarget > 0);
        void save() {
          if (!valid) return;
          state.setRitualGoal(
            year,
            month,
            h,
            weekly: weekly,
            target: parsedTarget,
            unit: parsedTarget == null ? '' : unit.trim(),
          );
          Navigator.pop(ctx);
        }

        final shownWeekly = weekly ?? lastWeekly;
        return ConfirmOnEnter(
          preserveTextInput: true,
          onConfirm: valid ? save : () {},
          child: AppAlertDialog(
            title: h.name,
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DialogSection(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('FREQUENCY', style: capsLabel(p.inkMuted)),
                          const SizedBox(height: 10),
                          SegmentedPills(
                            labels: const ['Weekdays', 'Times a week'],
                            selected: weekly == null ? 0 : 1,
                            expand: true,
                            onSelect: (i) => refresh(() {
                              if (i == 0) {
                                if (weekly != null) lastWeekly = weekly!;
                                weekly = null;
                              } else {
                                weekly ??= lastWeekly;
                              }
                            }),
                          ),
                          Fold(
                            open: weekly != null,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      for (var n = 1; n <= 7; n++) ...[
                                        if (n > 1) const SizedBox(width: 6),
                                        Expanded(
                                          child: _DayCountPill(
                                            value: n,
                                            selected: shownWeekly == n,
                                            onTap: () => refresh(() => weekly = lastWeekly = n),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '$shownWeekly ${shownWeekly == 1 ? 'time' : 'times'} each week',
                                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    DialogSection(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('DAILY TARGET', style: capsLabel(p.inkMuted)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: DialogField(
                                  label: 'Target (optional)',
                                  initialValue: target,
                                  hintText: 'e.g. 20',
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.done,
                                  onChanged: (v) => refresh(() => target = v),
                                  onFieldSubmitted: (_) => save(),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 3,
                                child: DialogField(
                                  label: 'Unit',
                                  initialValue: unit,
                                  hintText: 'pages, min…',
                                  textInputAction: TextInputAction.done,
                                  onChanged: (v) => unit = v,
                                  onFieldSubmitted: (_) => save(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(ctx)),
              DialogConfirm(label: 'Save', onPressed: valid ? save : null),
            ],
          ),
        );
      },
    ),
  );
}

class _DayCountPill extends StatelessWidget {
  const _DayCountPill({required this.value, required this.selected, required this.onTap});

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      focusable: true,
      semanticLabel: '$value times a week',
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.click),
        curve: Motion.clickCurve,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? p.done : p.empty.withValues(alpha: hover ? 0.9 : 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? p.done : p.borderSoft),
        ),
        child: Text(
          '$value',
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? p.onDone : p.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

Future<void> enterRitualAmount(BuildContext context, DateTime day, Habit h) async {
  final state = AppScope.read(context);
  final current = state.amountOn(day, h);
  await showAppDialog<void>(
    context: context,
    builder: (_) => _AmountDialog(state: state, day: day, habit: h, current: current),
  );
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.state, required this.day, required this.habit, required this.current});

  final AppState state;
  final DateTime day;
  final Habit habit;
  final int current;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _controller = TextEditingController(text: widget.current == 0 ? '' : '${widget.current}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setAmount(int value) {
    final next = value <= 0 ? '0' : '$value';
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final h = widget.habit;
    final trimmed = _controller.text.trim();
    final parsed = int.tryParse(trimmed);
    final valid = (parsed != null && parsed >= 0) || (trimmed.isEmpty && widget.current > 0);
    final shownValue = parsed ?? (trimmed.isEmpty ? 0 : widget.current);
    final target = h.target;
    final ratio = target == null || target <= 0 ? 0.0 : (shownValue / target).clamp(0.0, 1.0);

    void save() {
      if (!valid) return;
      widget.state.recordAmount(widget.day, h, parsed ?? 0);
      Navigator.pop(context);
    }

    return ConfirmOnEnter(
      preserveTextInput: true,
      onConfirm: valid ? save : () {},
      child: AppAlertDialog(
        title: h.name,
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (target != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$shownValue of $target ${h.unit ?? ''}'.trim(),
                          style: TextStyle(
                            fontFamily: Fonts.ui,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: p.ink,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Text(
                        '${(ratio * 100).round()}%',
                        style: TextStyle(
                          fontFamily: Fonts.ui,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ratio >= 1 ? p.accent : p.inkMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 8,
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(color: p.empty, borderRadius: BorderRadius.circular(4)),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: ratio),
                      duration: context.themed(Motion.click),
                      curve: Motion.clickCurve,
                      builder: (context, t, _) => FractionallySizedBox(
                        widthFactor: t,
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(color: p.done, borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                DialogField(
                  label: target == null ? (h.unit ?? 'Amount') : '${h.unit ?? 'Amount'} · target $target',
                  controller: _controller,
                  hintText: '0',
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (_) => save(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _QuickStepPill(
                      label: '−1',
                      onTap: () => _setAmount((shownValue - 1).clamp(0, 999999)),
                    ),
                    _QuickStepPill(label: '+1', onTap: () => _setAmount(shownValue + 1)),
                    _QuickStepPill(label: '+5', onTap: () => _setAmount(shownValue + 5)),
                    if (target != null && shownValue != target)
                      _QuickStepPill(
                        label: 'Done ($target)',
                        highlighted: true,
                        onTap: () => _setAmount(target),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(context)),
          DialogConfirm(label: 'Save', onPressed: valid ? save : null),
        ],
      ),
    );
  }
}

class _QuickStepPill extends StatelessWidget {
  const _QuickStepPill({required this.label, required this.onTap, this.highlighted = false});

  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      focusable: true,
      semanticLabel: label,
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.click),
        curve: Motion.clickCurve,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: highlighted
              ? Color.lerp(p.tile, p.done, hover ? 0.28 : 0.18)
              : p.empty.withValues(alpha: hover ? 0.9 : 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: highlighted ? p.done : p.borderSoft),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: Fonts.ui,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

String ritualProgress(AppState state, DateTime day, Habit habit) => [
  habit.name,
  if (habit.target != null) '${state.amountOn(day, habit)}/${habit.target} ${habit.unit ?? ''}'.trim(),
  if (habit.weekly != null) '${state.weeklyDone(day, habit)}/${habit.weekly} this week',
].join(' · ');
