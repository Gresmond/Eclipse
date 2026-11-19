import 'app_dialog.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../data/personal_export.dart';
import '../data/export_native.dart' if (dart.library.js_interop) '../data/export_web.dart';

class PersonalDataActions extends StatefulWidget {
  const PersonalDataActions({super.key});
  @override
  State<PersonalDataActions> createState() => _PersonalDataActionsState();
}

class _PersonalDataActionsState extends State<PersonalDataActions> {
  bool busy = false;
  String? message;
  Future<void> _export(bool calendar) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final state = AppScope.read(context);
      state.saveDrafts();
      final now = DateTime.now();
      final name = 'Eclipse-${dateKey(state.today)}-${now.microsecondsSinceEpoch}.${calendar ? 'ics' : 'zip'}';
      final bytes = calendar
          ? utf8.encode(calendarExport(state.store, state.today, generated: now))
          : exportBundle(state.store, state.today, generated: now);
      final saved = await saveExport(name, bytes);
      if (mounted && saved != null) setState(() => message = 'Saved $saved');
    } catch (e) {
      if (mounted) setState(() => message = 'Export failed · $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        children: [
          TextButton(
            onPressed: () => showAppDialog<void>(context: context, builder: (_) => const _Reflections()),
            child: const Text('Reflections'),
          ),
          TextButton(onPressed: busy ? null : () => _export(false), child: const Text('Export data (.zip)')),
          TextButton(onPressed: busy ? null : () => _export(true), child: const Text('Export calendar (.ics)')),
        ],
      ),
      if (message != null) Text(message!),
    ],
  );
}

class _Reflections extends StatefulWidget {
  const _Reflections();
  @override
  State<_Reflections> createState() => _ReflectionsState();
}

class _ReflectionsState extends State<_Reflections> {
  bool monthly = false;
  int offset = 0;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(
      context,
      (s) => (s.today, s.todosRevision, s.habitsRevision, s.entriesRevision, s.journalRevision, s.training.revision),
    );
    final t = state.today;
    final start = monthly
        ? DateTime(t.year, t.month + offset)
        : DateTime(t.year, t.month, t.day - t.weekday + 1 + offset * 7);
    final end = monthly ? DateTime(start.year, start.month + 1) : DateTime(start.year, start.month, start.day + 7);
    final args = [dateKey(start), dateKey(end)], db = state.store.raw;
    int count(String sql) => db.select(sql, args).first.columnAt(0) as int;
    final marks = db.select(
      'SELECT EXISTS(SELECT 1 FROM sleep_habits s WHERE s.habit_id=e.habit_id) AS sleep, sum(status=1) AS done, count(*) AS logged FROM entries e WHERE day>=? AND day<? AND status IN(1,2) GROUP BY sleep',
      args,
    );
    String score(int type) {
      final r = marks.where((r) => r['sleep'] == type).firstOrNull;
      return r == null ? 'No marks recorded' : '${r['done']} of ${r['logged']} marks done';
    }

    final shift = '-${state.dayStartHour} hours';
    final tasks =
        db
                .select(
                  r"""
      WITH completions AS (
        SELECT uid, date(done_at,'localtime',?3) AS completed FROM todos WHERE done=1
        UNION ALL
        SELECT uid, coalesce(date(json_extract(snapshot,'$.done_at'),'localtime',?3),day)
        FROM todo_history WHERE json_extract(snapshot,'$.done')=1
      ) SELECT count(DISTINCT uid) AS n FROM completions WHERE completed>=?1 AND completed<?2
    """,
                  [...args, shift],
                )
                .first['n']
            as int;
    final journalWorkouts = count(
      'SELECT count(DISTINCT t.day) FROM training_sets t JOIN journal j ON j.day=t.day WHERE t.day>=? AND t.day<? AND t.reps>0 AND length(trim(j.text))>0',
    );
    final workouts = count('SELECT count(DISTINCT day) FROM training_sets WHERE day>=? AND day<? AND reps>0');
    final journal = db.select('SELECT day,text FROM journal WHERE day>=? AND day<? ORDER BY day DESC', args);
    return AppAlertDialog(
      title: 'Reflections',
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Weekly')),
                  ButtonSegment(value: true, label: Text('Monthly')),
                ],
                selected: {monthly},
                onSelectionChanged: (v) => setState(() {
                  monthly = v.first;
                  offset = 0;
                }),
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous period',
                    onPressed: () => setState(() => offset--),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(child: Text(dateKey(start), textAlign: TextAlign.center)),
                  IconButton(
                    tooltip: 'Next period',
                    onPressed: offset < 0 ? () => setState(() => offset++) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              for (final (title, value) in [
                ('Sleep schedule', score(1)),
                ('Rituals', score(0)),
                ('Tasks completed', '$tasks'),
                ('Training days', '$workouts'),
                ('Journal entries', '${journal.length}'),
              ])
                ListTile(title: Text(title), subtitle: Text(value)),
              if (workouts > 0) Text('You wrote in your journal on $journalWorkouts of $workouts training days.'),
              for (final r in journal)
                ExpansionTile(title: Text(r['day'] as String), children: [SelectableText(r['text'] as String)]),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
