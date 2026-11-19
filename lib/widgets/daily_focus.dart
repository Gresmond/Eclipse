import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';

class DailyFocus extends StatelessWidget {
  const DailyFocus({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.watch(context, (s) => (s.today, s.todosRevision, s.focusEnabled, s.focusUid));
    if (!state.focusEnabled) return const SizedBox.shrink();
    final tasks = state.orderedTodos(TodoScope.today).where((t) => !t.done && t.uid != null);
    if (tasks.isEmpty) return const SizedBox.shrink();
    final selected = tasks.where((t) => t.uid == state.focusUid).firstOrNull;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        leading: const Icon(Icons.push_pin_rounded),
        title: DropdownButton<String>(
          isExpanded: true,
          value: selected?.uid,
          hint: const Text('Choose today’s focus'),
          onChanged: state.setFocus,
          items: [
            for (final task in tasks)
              DropdownMenuItem(
                value: task.uid,
                child: Text(task.text, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
        trailing: selected == null
            ? null
            : IconButton(tooltip: 'Unpin focus', icon: const Icon(Icons.close), onPressed: () => state.setFocus(null)),
      ),
    );
  }
}
