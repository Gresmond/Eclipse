import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';

Future<void> editRitualGoal(BuildContext context, Habit h, int year, int month) async {
  final state = AppScope.read(context);
  var weekly = h.weekly, target = h.target?.toString() ?? '', unit = h.unit ?? '';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
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

        return ConfirmOnEnter(
          preserveTextInput: true,
          onConfirm: valid ? save : () {},
          child: AppAlertDialog(
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
                    textInputAction: TextInputAction.done,
                    onChanged: (v) => refresh(() => target = v),
                    onFieldSubmitted: (_) => save(),
                  ),
                  TextFormField(
                    initialValue: unit,
                    decoration: const InputDecoration(labelText: 'Unit, e.g. pages'),
                    textInputAction: TextInputAction.done,
                    onChanged: (v) => unit = v,
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

Future<void> enterRitualAmount(BuildContext context, DateTime day, Habit h) async {
  final state = AppScope.read(context);
  final current = state.amountOn(day, h);
  var amount = current == 0 ? '' : '$current';
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) {
        final trimmed = amount.trim();
        final parsed = int.tryParse(trimmed);
        final valid = (parsed != null && parsed >= 0) || (trimmed.isEmpty && current > 0);
        void save() {
          if (!valid) return;
          state.recordAmount(day, h, parsed ?? 0);
          Navigator.pop(ctx);
        }

        return ConfirmOnEnter(
          preserveTextInput: true,
          onConfirm: valid ? save : () {},
          child: AppAlertDialog(
            title: h.name,
            content: TextFormField(
              initialValue: amount,
              keyboardType: TextInputType.number,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '${h.unit ?? 'Amount'} · target ${h.target}',
                hintText: '0',
              ),
              onChanged: (v) => refresh(() => amount = v),
              onFieldSubmitted: (_) => save(),
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

String ritualProgress(AppState state, DateTime day, Habit habit) => [
  habit.name,
  if (habit.target != null) '${state.amountOn(day, habit)}/${habit.target} ${habit.unit ?? ''}'.trim(),
  if (habit.weekly != null) '${state.weeklyDone(day, habit)}/${habit.weekly} this week',
].join(' · ');
