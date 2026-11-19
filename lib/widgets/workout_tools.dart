import '../theme/pixels.dart';
import 'app_dialog.dart';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../training.dart';

Future<void> editSetDetails(BuildContext context, TrainingSet set, Exercise exercise) async {
  final log = AppScope.read(context).training;
  var note = set.note ?? '', effort = set.rpe?.toString() ?? '', load = set.weight?.toString() ?? '';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final rpe = double.tryParse(effort), kg = double.tryParse(load);
        final valid =
            (effort.isEmpty || rpe != null && rpe >= 1 && rpe <= 10) &&
            (!exercise.bodyweight || load.isEmpty || kg != null && kg.isFinite && kg >= 0);
        return AppAlertDialog(
          title: exercise.name,
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Set note'),
                  onChanged: (v) => note = v,
                ),
                TextFormField(
                  initialValue: effort,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Effort (RPE 1–10)'),
                  onChanged: (v) => refresh(() => effort = v),
                ),
                if (exercise.bodyweight)
                  TextFormField(
                    initialValue: load,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Added weight (kg)'),
                    onChanged: (v) => refresh(() => load = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: valid
                  ? () {
                      log.setDetails(
                        set,
                        note,
                        double.tryParse(effort),
                        addedWeight: exercise.bodyweight ? double.tryParse(load) ?? 0 : null,
                      );
                      Navigator.pop(ctx);
                    }
                  : null,
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

class WorkoutToolsButton extends StatelessWidget {
  const WorkoutToolsButton({super.key, required this.day});
  final DateTime day;
  @override
  Widget build(BuildContext context) => PixelTooltip(
    message: 'Workout tools',
    child: IconButton(
      icon: const Icon(Icons.tune_rounded),
      onPressed: () => showAppDialog<void>(
        context: context,
        builder: (_) => _Tools(day: day),
      ),
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
  String name = '', kg = '';
  bool sets = true;
  @override
  Widget build(BuildContext context) {
    final log = AppScope.watch(context, (s) => s.training.revision).training;
    final day = widget.day, totals = log.weeklyVolume(day), session = log.session(day);
    final maxValue = totals.values.fold<double>(1, (m, v) {
      final value = sets ? v.$1.toDouble() : v.$2;
      return value > m ? value : m;
    });
    final mass = log.bodyMass(day);
    return AppAlertDialog(
      title: 'Workout tools · ${dayAndMonth(day, today: day)}',
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: kg,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Bodyweight (kg)', hintText: mass?.toString()),
                onChanged: (v) => setState(() => kg = v),
              ),
              TextButton(
                onPressed: (double.tryParse(kg) ?? 0) > 0
                    ? () {
                        log.weighIn(day, double.parse(kg));
                      }
                    : null,
                child: const Text('Save weigh-in'),
              ),
              if (mass != null) Text('Latest weigh-in · $mass kg'),
              const Divider(),
              for (final (id, label) in log.routines)
                ListTile(
                  title: Text(label),
                  trailing: const Icon(Icons.add),
                  onTap: () {
                    log.applyRoutine(id, day);
                    Navigator.pop(context);
                  },
                ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Routine name'),
                onChanged: (v) => setState(() => name = v),
              ),
              TextButton(
                onPressed: name.trim().isEmpty || session.isEmpty
                    ? null
                    : () {
                        log.saveRoutine(name, day);
                        Navigator.pop(context);
                      },
                child: const Text('Save session as routine'),
              ),
              const Divider(),
              Text('This week', style: Theme.of(context).textTheme.titleMedium),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Sets')),
                  ButtonSegment(value: false, label: Text('Volume (kg)')),
                ],
                selected: {sets},
                onSelectionChanged: (v) => setState(() => sets = v.first),
              ),
              if (totals.isEmpty) const Text('No sets logged this week.'),
              for (final entry in totals.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${entry.key.label} · ${sets ? entry.value.$1 : entry.value.$2.toStringAsFixed(1)}'),
                      LinearProgressIndicator(value: (sets ? entry.value.$1 : entry.value.$2) / maxValue),
                    ],
                  ),
                ),
              if (mass != null)
                for (final (e, rows) in session.where((r) => r.$1.bodyweight))
                  for (final s in rows.where((s) => (s.weight ?? 0) > 0))
                    if (estimateOneRepMax(mass + s.weight!, s.reps) case final estimate?)
                      Text('${e.name} · ${estimate.toStringAsFixed(1)} kg estimated total 1RM'),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
