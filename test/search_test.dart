import 'package:eclipse/app_state.dart';
import 'package:eclipse/data/search.dart';
import 'package:eclipse/data/store.dart';
import 'package:eclipse/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 28, 9);
  late Store store;
  late AppState state;
  setUp(() {
    store = Store.memory();
    state = AppState(store, clock: () => now);
  });
  tearDown(() {
    state.dispose();
    store.close();
  });

  TodoItem task(String text) => [for (final list in state.todos.values) ...list].singleWhere((t) => t.text == text);

  test('finds tasks and journal entries holding every word, newest first', () {
    state.addTodo(TodoScope.today, 'Call the dentist');
    state.toggleTodo(task('Call the dentist'));
    state.addTodo(TodoScope.week, 'Dentist bill', dueDate: DateTime(2026, 11, 2));
    store.setJournal('2026-10-20', 'Went to the dentist. Didn’t hurt.');

    final hits = SearchIndex(store).search('DENTIST');
    expect(
      [for (final h in hits) (h.isJournal, h.text, dateKey(h.day))],
      [
        (false, 'Dentist bill', '2026-11-02'),
        (false, 'Call the dentist', '2026-10-28'),
        (true, 'Went to the dentist. Didn’t hurt.', '2026-10-20'),
      ],
    );
    expect(hits[1].done, isTrue);
    expect(SearchIndex(store).search("dentist didn't"), hasLength(1), reason: 'straight quotes match curly ones');
    expect(SearchIndex(store).search('bill call'), isEmpty, reason: 'every word must be in the same one');
  });

  test('a subtask match shows its task, with the subtask', () {
    state.addTodo(TodoScope.today, 'Pack');
    state.setTodoSubtasks(TodoScope.today, task('Pack'), const [TodoSubtask('Passport'), TodoSubtask('Charger')]);
    final hit = SearchIndex(store).search('pack passport').single;
    expect((hit.text, hit.subtask), ('Pack', 'Passport'));
  });

  test('opening a result shows its day and marks it to light', () {
    state.addTodo(TodoScope.today, 'Old thing');
    final uid = task('Old thing').uid!;
    state.showFound(DateTime(2026, 10, 20), uid);
    expect(state.viewDay, DateTime(2026, 10, 20));
    expect(state.found?.target, uid);
    state.showFound(DateTime(2026, 11, 2), uid);
    expect(state.viewDay, isNull, reason: 'a later day is shown from today');
  });

  test('matches are lit wherever they fall, overlaps merged', () {
    expect(matchRanges('Dentist bill, dentist', ['dent', 'ntist']), [(0, 7), (14, 21)]);
  });
}
