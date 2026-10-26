import 'package:flutter/material.dart';

import '../models.dart';

class RitualName extends StatelessWidget {
  const RitualName({super.key, required this.habit, required this.style, required this.maxLines});
  final Habit habit;
  final TextStyle style;
  final int maxLines;
  @override
  Widget build(BuildContext context) =>
      Text(habit.name, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
}
