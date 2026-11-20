import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../screens/training_view.dart' show groupColour;
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../training.dart';
import '../training_log.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
import 'glide_pill.dart';
import 'tile.dart';

double? _parseDecimal(String raw) {
  final cleaned = raw.trim().replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  return value != null && value.isFinite ? value : null;
}

Future<void> editSetDetails(BuildContext context, TrainingSet set, Exercise exercise) async {
  final log = AppScope.read(context).training;
  var note = set.note ?? '', effort = set.rpe?.toString() ?? '', load = set.weight?.toString() ?? '';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final effortEmpty = effort.trim().isEmpty;
        final loadEmpty = load.trim().isEmpty;
        final rpe = _parseDecimal(effort), kg = _parseDecimal(load);
        final valid =
            (effortEmpty || rpe != null && rpe >= 1 && rpe <= 10) &&
            (!exercise.bodyweight || loadEmpty || kg != null && kg >= 0);
        void save() {
          if (!valid) return;
          log.setDetails(
            set,
            note,
            effortEmpty ? null : rpe,
            addedWeight: exercise.bodyweight && !loadEmpty ? kg : null,
            clearWeight: exercise.bodyweight && loadEmpty,
          );
          Navigator.pop(ctx);
        }

        return ConfirmOnEnter(
          preserveTextInput: true,
          onConfirm: valid ? save : () {},
          child: AppAlertDialog(
            title: exercise.name,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: note,
                    maxLines: 2,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Set note'),
                    onChanged: (v) => note = v,
                    onFieldSubmitted: (_) => save(),
                  ),
                  TextFormField(
                    initialValue: effort,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Effort (RPE 1–10)'),
                    onChanged: (v) => refresh(() => effort = v),
                    onFieldSubmitted: (_) => save(),
                  ),
                  if (exercise.bodyweight)
                    TextFormField(
                      initialValue: load,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(labelText: 'Added weight (kg)'),
                      onChanged: (v) => refresh(() => load = v),
                      onFieldSubmitted: (_) => save(),
                    ),
                ],
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
              content: TextFormField(
                initialValue: draft,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Routine name'),
                onChanged: (v) => refresh(() => draft = v),
                onFieldSubmitted: (_) => submit(),
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

    return AppAlertDialog(
      title: 'Workout tools · ${dayAndMonth(day, today: state.today)}',
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _kg,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(labelText: 'Bodyweight (kg)', hintText: mass?.toString()),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (!canSaveWeighIn) return;
                  log.weighIn(day, parsedKg);
                  _kg.clear();
                  setState(() {});
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: canSaveWeighIn
                      ? () {
                          log.weighIn(day, parsedKg);
                          _kg.clear();
                          setState(() {});
                        }
                      : null,
                  child: const Text('Save weigh-in'),
                ),
              ),
              if (mass != null)
                Text(
                  'Latest weigh-in · $mass kg',
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                ),
              Divider(color: p.border),
              for (final (id, label) in log.routines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label, style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink)),
                  onTap: () {
                    log.applyRoutine(id, day);
                    Navigator.pop(context);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Rename routine',
                        iconSize: 16,
                        color: p.inkMuted,
                        icon: const Icon(Icons.edit_rounded),
                        onPressed: () => _renameRoutine(log, id, label),
                      ),
                      IconButton(
                        tooltip: 'Delete routine',
                        iconSize: 16,
                        color: p.missedInk,
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => log.deleteRoutine(id),
                      ),
                      IconButton(
                        tooltip: 'Apply routine',
                        iconSize: 18,
                        color: p.accent,
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () {
                          log.applyRoutine(id, day);
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _routine,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Routine name'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (!canSaveRoutine) return;
                  log.saveRoutine(routineName, day);
                  _routine.clear();
                  setState(() {});
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: canSaveRoutine
                      ? () {
                          log.saveRoutine(routineName, day);
                          _routine.clear();
                          setState(() {});
                        }
                      : null,
                  child: const Text('Save session as routine'),
                ),
              ),
              Divider(color: p.border),
              Text('THIS WEEK', style: capsLabel(p.inkMuted)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedPills(
                  labels: const ['Sets', 'Volume (kg)'],
                  selected: sets ? 0 : 1,
                  compact: true,
                  onSelect: (i) => setState(() => sets = i == 0),
                ),
              ),
              const SizedBox(height: 8),
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
                        Text(
                          '${g.label} · ${sets ? '${v.$1} ${v.$1 == 1 ? 'set' : 'sets'}' : '${v.$2.toStringAsFixed(1)} kg'}',
                          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.ink),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: (sets ? v.$1 : v.$2) / maxValue,
                          color: groupColour(g, p),
                          backgroundColor: p.empty,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],
                    ),
                  ),
              if (mass != null) ...[
                const SizedBox(height: 10),
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
                            padding: const EdgeInsets.only(top: 4),
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
      ),
      actions: [DialogDismiss(label: 'Close', onPressed: () => Navigator.pop(context))],
    );
  }
}
