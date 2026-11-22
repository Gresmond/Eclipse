import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../screens/training_view.dart' show groupColour;
import '../theme/app_theme.dart';
import '../theme/pixels.dart';
import '../theme/tokens.dart';
import '../training.dart';
import '../training_log.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'fade_menu.dart';
import 'glide_pill.dart';
import 'hover_fill.dart';
import 'tile.dart';

double? _parseDecimal(String raw) {
  final cleaned = raw.trim().replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  return value != null && value.isFinite ? value : null;
}

Future<void> editSetDetails(BuildContext context, TrainingSet set, Exercise exercise) async {
  final log = AppScope.read(context).training;
  await showAppDialog<void>(
    context: context,
    builder: (_) => _SetDetailsDialog(log: log, set: set, exercise: exercise),
  );
}

class _SetDetailsDialog extends StatefulWidget {
  const _SetDetailsDialog({required this.log, required this.set, required this.exercise});

  final TrainingLog log;
  final TrainingSet set;
  final Exercise exercise;

  @override
  State<_SetDetailsDialog> createState() => _SetDetailsDialogState();
}

class _SetDetailsDialogState extends State<_SetDetailsDialog> {
  static const _rpeChoices = ['7', '8', '9', '9.5', '10'];

  late final _note = TextEditingController(text: widget.set.note ?? '');
  late final _effort = TextEditingController(text: widget.set.rpe?.toString() ?? '');
  late final _load = TextEditingController(text: widget.set.weight?.toString() ?? '');

  @override
  void dispose() {
    _note.dispose();
    _effort.dispose();
    _load.dispose();
    super.dispose();
  }

  void _pickRpe(String value) {
    final current = _effort.text.trim();
    final next = current == value ? '' : value;
    _effort.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effortText = _effort.text.trim();
    final effortEmpty = effortText.isEmpty;
    final loadEmpty = _load.text.trim().isEmpty;
    final rpe = _parseDecimal(effortText);
    final kg = _parseDecimal(_load.text);
    final valid =
        (effortEmpty || rpe != null && rpe >= 1 && rpe <= 10) &&
        (!widget.exercise.bodyweight || loadEmpty || kg != null && kg >= 0);

    void save() {
      if (!valid) return;
      widget.log.setDetails(
        widget.set,
        _note.text,
        effortEmpty ? null : rpe,
        addedWeight: widget.exercise.bodyweight && !loadEmpty ? kg : null,
        clearWeight: widget.exercise.bodyweight && loadEmpty,
      );
      Navigator.pop(context);
    }

    return ConfirmOnEnter(
      preserveTextInput: true,
      onConfirm: valid ? save : () {},
      child: AppAlertDialog(
        title: widget.exercise.name,
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DialogField(
                  label: 'Set note',
                  controller: _note,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => save(),
                ),
                const SizedBox(height: 10),
                DialogField(
                  label: 'Effort (RPE 1–10)',
                  controller: _effort,
                  hintText: 'e.g. 8',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (_) => save(),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final choice in _rpeChoices)
                      _RpePill(
                        label: choice,
                        selected: rpe != null && _parseDecimal(choice) == rpe,
                        onTap: () => _pickRpe(choice),
                      ),
                  ],
                ),
                if (widget.exercise.bodyweight) ...[
                  const SizedBox(height: 10),
                  DialogField(
                    label: 'Added weight (kg)',
                    controller: _load,
                    hintText: '0',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onFieldSubmitted: (_) => save(),
                  ),
                ],
                if (!valid) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Enter an RPE between 1 and 10${widget.exercise.bodyweight ? ' and a weight of 0 or more' : ''}.',
                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.missedInk),
                  ),
                ],
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

class _RpePill extends StatelessWidget {
  const _RpePill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      focusable: true,
      semanticLabel: 'RPE $label',
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: context.themed(Motion.click),
        curve: Motion.clickCurve,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? p.done : p.empty.withValues(alpha: hover ? 0.9 : 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? p.done : p.borderSoft),
        ),
        child: Text(
          label,
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

class WorkoutToolsButton extends StatelessWidget {
  const WorkoutToolsButton({super.key, required this.day});
  final DateTime day;
  @override
  Widget build(BuildContext context) => HeaderIconButton(
    icon: Icons.tune_rounded,
    tooltip: 'Workout tools',
    onPressed: () => showAppDialog<void>(
      context: context,
      builder: (_) => _Tools(day: day),
    ),
  );
}

class _Tools extends StatefulWidget {
  const _Tools({required this.day});
  final DateTime day;
  @override
  State<_Tools> createState() => _ToolsState();
}

class _ToolsState extends State<_Tools> {
  final _kg = TextEditingController();
  final _routine = TextEditingController();
  bool sets = true;

  @override
  void dispose() {
    _kg.dispose();
    _routine.dispose();
    super.dispose();
  }

  Future<void> _renameRoutine(TrainingLog log, String uid, String current) async {
    var draft = current;
    final renamed = await showAppDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          final valid = draft.trim().isNotEmpty;
          void submit() {
            if (valid) Navigator.pop(ctx, draft.trim());
          }

          return ConfirmOnEnter(
            preserveTextInput: true,
            onConfirm: submit,
            child: AppAlertDialog(
              title: 'Rename routine',
              content: SizedBox(
                width: 340,
                child: DialogField(
                  label: 'Routine name',
                  initialValue: draft,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onChanged: (v) => refresh(() => draft = v),
                  onFieldSubmitted: (_) => submit(),
                ),
              ),
              actions: [
                DialogDismiss(label: 'Cancel', onPressed: () => Navigator.pop(ctx)),
                DialogConfirm(label: 'Save', onPressed: valid ? submit : null),
              ],
            ),
          );
        },
      ),
    );
    if (renamed != null && renamed.isNotEmpty) log.renameRoutine(uid, renamed);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(context, (s) => (s.training.revision, s.today));
    final log = state.training;
    final day = widget.day, totals = log.weeklyVolume(day), session = log.session(day);
    final maxValue = totals.values.fold<double>(1, (m, v) {
      final value = sets ? v.$1.toDouble() : v.$2;
      return value > m ? value : m;
    });
    final mass = log.bodyMass(day);
    final parsedKg = _parseDecimal(_kg.text);
    final canSaveWeighIn = parsedKg != null && parsedKg > 0;
    final routineName = _routine.text.trim();
    final canSaveRoutine = routineName.isNotEmpty && session.isNotEmpty;

    void saveWeighIn() {
      if (!canSaveWeighIn) return;
      log.weighIn(day, parsedKg);
      _kg.clear();
      setState(() {});
    }

    void saveRoutine() {
      if (!canSaveRoutine) return;
      log.saveRoutine(routineName, day);
      _routine.clear();
      setState(() {});
    }

    return AppAlertDialog(
      title: 'Workout tools · ${dayAndMonth(day, today: state.today)}',
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DialogSection(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('BODYWEIGHT', style: capsLabel(p.inkMuted)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DialogField(
                            label: 'Weigh-in (kg)',
                            controller: _kg,
                            hintText: mass?.toString() ?? '0',
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                            onFieldSubmitted: (_) => saveWeighIn(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: canSaveWeighIn ? saveWeighIn : null,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                    if (mass != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Latest weigh-in · $mass kg',
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              DialogSection(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('ROUTINES', style: capsLabel(p.inkMuted)),
                    const SizedBox(height: 8),
                    if (log.routines.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Save today’s exercises as a routine to reuse them in one tap.',
                          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                        ),
                      )
                    else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (id, label) in log.routines)
                              FadeMenuRow(
                                height: 44,
                                onTap: () {
                                  log.applyRoutine(id, day);
                                  Navigator.pop(context);
                                },
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: Fonts.ui,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          color: p.ink,
                                        ),
                                      ),
                                    ),
                                    _RoutineIconAction(
                                      tooltip: 'Rename routine',
                                      icon: Icons.edit_rounded,
                                      size: 16,
                                      color: p.inkMuted,
                                      onPressed: () => _renameRoutine(log, id, label),
                                    ),
                                    _RoutineIconAction(
                                      tooltip: 'Delete routine',
                                      icon: Icons.delete_outline_rounded,
                                      size: 16,
                                      color: p.missedInk,
                                      onPressed: () => log.deleteRoutine(id),
                                    ),
                                    _RoutineIconAction(
                                      tooltip: 'Apply routine',
                                      icon: Icons.add_rounded,
                                      size: 18,
                                      color: p.accent,
                                      onPressed: () {
                                        log.applyRoutine(id, day);
                                        Navigator.pop(context);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: DialogField(
                            label: 'Save session as routine',
                            controller: _routine,
                            hintText: session.isEmpty ? 'Add exercises first' : 'e.g. Push A',
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                            onFieldSubmitted: (_) => saveRoutine(),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: canSaveRoutine ? saveRoutine : null,
                          child: const Text('Save'),
                        ),
                      ],
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
                    Row(
                      children: [
                        Expanded(child: Text('THIS WEEK', style: capsLabel(p.inkMuted))),
                        SegmentedPills(
                          labels: const ['Sets', 'Volume (kg)'],
                          selected: sets ? 0 : 1,
                          compact: true,
                          onSelect: (i) => setState(() => sets = i == 0),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (totals.isEmpty)
                      Text(
                        'No sets logged this week.',
                        style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                      ),
                    for (final g in MuscleGroup.values)
                      if (totals[g] case final v?)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(color: groupColour(g, p), shape: BoxShape.circle),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      g.label,
                                      style: TextStyle(
                                        fontFamily: Fonts.ui,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: p.ink,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    sets ? '${v.$1} ${v.$1 == 1 ? 'set' : 'sets'}' : '${v.$2.toStringAsFixed(1)} kg',
                                    style: TextStyle(
                                      fontFamily: Fonts.ui,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: p.inkMuted,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Container(
                                width: double.infinity,
                                height: 6,
                                alignment: Alignment.centerLeft,
                                decoration: BoxDecoration(color: p.empty, borderRadius: BorderRadius.circular(4)),
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(end: ((sets ? v.$1 : v.$2) / maxValue).clamp(0.0, 1.0)),
                                  duration: context.themed(Motion.morph),
                                  curve: Motion.morphCurve,
                                  builder: (context, t, _) => FractionallySizedBox(
                                    widthFactor: t,
                                    child: Container(
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: groupColour(g, p),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    if (mass != null) ...[
                      for (final (e, rows) in session.where((r) => r.$1.bodyweight))
                        () {
                          double? best;
                          for (final s in rows) {
                            if ((s.weight ?? 0) <= 0) continue;
                            final estimate = estimateOneRepMax(mass + s.weight!, s.reps);
                            if (estimate != null && (best == null || estimate > best)) best = estimate;
                          }
                          return best == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    '${e.name} · ${best.toStringAsFixed(1)} kg estimated total 1RM',
                                    style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                                  ),
                                );
                        }(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [DialogDismiss(label: 'Close', onPressed: () => Navigator.pop(context))],
    );
  }
}

class _RoutineIconAction extends StatelessWidget {
  const _RoutineIconAction({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PixelTooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const WidgetStatePropertyAll(Size.square(28)),
          maximumSize: const WidgetStatePropertyAll(Size.square(28)),
          shape: const WidgetStatePropertyAll(CircleBorder()),
          foregroundColor: WidgetStatePropertyAll(color),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused))
                ? p.empty.withValues(alpha: 0.8)
                : Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        icon: Icon(icon, size: size),
      ),
    );
  }
}
