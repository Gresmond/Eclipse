import 'dart:convert';
import 'dart:io';

import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:eclipse/widgets/note_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dialogue, nested quotes, apostrophes and measurements use curly marks', () {
    final cases = <String, String>{
      'He said "Hello".': 'He said “Hello”.',
      "She said 'Hello'.": 'She said ‘Hello’.',
      '''"Don't say 'never'," she said.''': '“Don’t say ‘never’,” she said.',
      '''Don't forget James' ruler: 6' 2", or 6′ 2″.''': 'Don’t forget James’ ruler: 6’ 2”, or 6’ 2”.',
      '''("Hello") — 'Goodbye'\n"Next line"''': '(“Hello”) — ‘Goodbye’\n“Next line”',
      '“Already curly” and ‘single’': '“Already curly” and ‘single’',
      "Back in '90s; 'tis fine": 'Back in ’90s; ’tis fine',
    };
    for (final entry in cases.entries) {
      expect(curlyQuotes(entry.key), entry.value);
      expect(curlyQuotes(entry.value), entry.value, reason: 'formatting must be idempotent');
    }
  });

  test('typing closing quotes preserves caret and leaves composing text alone', () {
    const formatter = NoteInputFormatter();
    var value = TextEditingValue.empty;
    for (final char in '"hello"'.split('')) {
      final next = TextEditingValue(
        text: '${value.text}$char',
        selection: TextSelection.collapsed(offset: value.text.length + 1),
      );
      value = formatter.formatEditUpdate(value, next);
      expect(value.selection.baseOffset, value.text.length);
    }
    expect(value.text, '“hello”');
    const composing = TextEditingValue(text: '"hello', composing: TextRange(start: 1, end: 6));
    expect(formatter.formatEditUpdate(value, composing), composing);
  });

  test('typed hyphens become en and em dashes with the caret after them', () {
    const formatter = NoteInputFormatter();
    String type(String keys) {
      var value = TextEditingValue.empty;
      for (final char in keys.split('')) {
        final next = TextEditingValue(
          text: '${value.text}$char',
          selection: TextSelection.collapsed(offset: value.text.length + 1),
        );
        value = formatter.formatEditUpdate(value, next);
        expect(value.selection.baseOffset, value.text.length);
      }
      return value.text;
    }

    expect(type('pages 1--5'), 'Pages 1–5');
    expect(type('wait---what'), 'Wait—what');
    expect(type('a - b'), 'A - b');
    expect(normaliseNote('pasted -- and --- dashes'), 'Pasted – and — dashes');
  });

  test('version 15 saved text and task history migrate once without losing metadata', () {
    final dir = Directory.systemTemp.createTempSync('eclipse-curly-quotes');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/test.db';
    var store = Store.open(path);
    final day = DateTime(2026, 10, 26);
    final habit = store.addHabit(2026, 10, 'Read "Dune"');
    store.setHabitNote(2026, 10, habit.id, "Don't rush");
    store.setNote('2026-10-26', habit.id, 'Said "done"');
    store.setJournal('2026-10-26', '''She said "I'm 6' 2"".''');
    final task = store.addTodo(TodoScope.today, day, 'Buy "Dune"');
    final children = TodoSubtask.encode([const TodoSubtask("Don't forget", done: true)]);
    store.raw.execute('UPDATE todos SET subtasks = ? WHERE id = ?', [children, task.id]);
    final uid = store.raw.select('SELECT uid FROM todos WHERE id = ?', [task.id]).single['uid'];
    store.raw.execute('INSERT OR REPLACE INTO todo_history VALUES (?, ?, ?)', [
      uid,
      '2026-10-25',
      jsonEncode({'text': 'Buy "Dune"', 'subtasks': children, 'done': true}),
    ]);
    store.raw.execute('PRAGMA user_version = 15');
    store.close();

    store = Store.open(path);
    expect(store.monthHabits(2026, 10).single.name, 'Read “Dune”');
    expect(store.monthHabits(2026, 10).single.description, 'Don’t rush');
    expect(store.journal('2026-10-26'), 'She said “I’m 6’ 2””.');
    final saved = store.todos(TodoScope.today, '2026-10-26').single;
    expect(saved.text, 'Buy “Dune”');
    expect(saved.subtasks.single.text, 'Don’t forget');
    expect(saved.subtasks.single.done, isTrue);
    final snapshot = jsonDecode(
      store.raw.select('SELECT snapshot FROM todo_history WHERE day = ?', ['2026-10-25']).single['snapshot'] as String,
    );
    expect(snapshot['text'], 'Buy “Dune”');
    expect(snapshot['done'], isTrue);
    expect(TodoSubtask.decode(snapshot['subtasks'] as String).single.text, 'Don’t forget');
    expect(store.raw.select('PRAGMA user_version').single.columnAt(0), Store.schemaVersion);
    store.raw.execute('DELETE FROM sync_dirty');
    store.close();

    store = Store.open(path);
    expect(store.raw.select('SELECT * FROM sync_dirty'), isEmpty, reason: 'do not rewrite on every launch');
    store.close();
  });
}
