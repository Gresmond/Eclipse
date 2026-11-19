import 'app_dialog.dart';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';

Future<void> editRitualGoal(BuildContext context, Habit h, int year, int month) async {
  final state = AppScope.read(context);
  var weekly = h.weekly, target = h.target?.toString() ?? '', unit = h.unit ?? '';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AppAlertDialog(
        title: h.name,
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: weekly ?? 0,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('Selected weekdays')),
                  for (var n = 1; n <= 7; n++) DropdownMenuItem(value: n, child: Text('$n times a week')),
                ],
                onChanged: (n) => refresh(() => weekly = n == 0 ? null : n),
              ),
              TextFormField(
                initialValue: target,
                decoration: const InputDecoration(labelText: 'Daily number target (optional)'),
                keyboardType: TextInputType.number,
                onChanged: (v) => refresh(() => target = v),
              ),
              TextFormField(
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'Unit, e.g. pages'),
                onChanged: (v) => unit = v,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: target.isEmpty || (int.tryParse(target) ?? 0) > 0
                ? () {
                    state.setRitualGoal(
                      year,
                      month,
                      h,
                      weekly: weekly,
                      target: int.tryParse(target),
                      unit: cleanNote(unit),
                    );
                    Navigator.pop(ctx);
                  }
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> enterRitualAmount(BuildContext context, DateTime day, Habit h) async {
  final state = AppScope.read(context);
  var amount = '${state.amountOn(day, h)}';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AppAlertDialog(
        title: h.name,
        content: TextFormField(
          initialValue: amount,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: '${h.unit ?? 'Amount'} · target ${h.target}'),
          onChanged: (v) => refresh(() => amount = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: (int.tryParse(amount) ?? -1) < 0
                ? null
                : () {
                    state.recordAmount(day, h, int.parse(amount));
                    Navigator.pop(ctx);
                  },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

String ritualProgress(AppState state, DateTime day, Habit habit) => [
  habit.name,
  if (habit.target != null) '${state.amountOn(day, habit)}/${habit.target} ${habit.unit ?? ''}'.trim(),
  if (habit.weekly != null) '${state.weeklyDone(day, habit)}/${habit.weekly} this week',
].join(' · ');
