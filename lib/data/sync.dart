import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'safe_write.dart';
import 'store.dart';

part 'sync_folder.dart';
part 'sync_registers.dart';

/// What one round of merging brought in from other computers.
class Incoming {
  Incoming(this.rows, this.from, [this.keptBoth = const {}, this.failed = const {}]);

  /// The (kind, rowkey) of each row that changed here.
  final Set<(String, String)> rows;

  /// The names of the computers they came from.
  final Set<String> from;

  /// Days whose journal entry was written on two computers at once, so
  /// both texts were kept.
  final Set<String> keptBoth;

  /// The batches, by place in the list merged, that couldn't be taken in:
  /// left as they were, to try again.
  final Set<int> failed;

  int get changes => rows.length;

  /// Days whose journal entry changed, to write out as files.
  Iterable<String> get journalDays => [
    for (final (kind, rowkey) in rows)
      if (kind == 'journal') rowkey,
  ];

  bool get isEmpty => rows.isEmpty;
}

/// Keeps rituals, ticks, to-dos and the journal the same on several
/// computers, through a folder that each of them copies to and from a
/// shared place (Eclipse's hidden folder in Google Drive).
///
/// Every field of every row is a register with a version per computer.
/// Each computer writes only its own registers, to its own folder, one
/// file per day of changes, so no file is ever written in two places.
/// Merging takes whichever edit saw the other; between two that didn't, the
/// later one wins, except for the journal, which keeps both texts.
///
/// What the app does by itself is never an edit that can beat yours: a day
/// start's moves aren't sent at all ([Store.local]), and what it fills in,
/// like a new month's list, goes without counting as having seen anything
/// ([Store.weak]), so any edit it hadn't heard of wins over it.
class SyncEngine implements AutomaticWrites {
  /// [clock] stands in for the time, in tests.
  SyncEngine(this.store, this.me, {this._clock}) {
    store.automatic = this;
    if (store.upgradedFrom case final from?) {
      store.upgradedFrom = null;
      _upgrade(from);
    }
  }

  final Store store;

  /// This computer's id: the name of its folder.
  final String me;

  Database get _db => store.raw;

  /// Milliseconds this computer's clock is behind Google's; its times are
  /// put right by it.
  int offset = 0;

  final int Function()? _clock;

  int _now() => (_clock?.call() ?? DateTime.now().millisecondsSinceEpoch) + offset;

  int? _lastTs, _lastSeq;

  /// The latest time of any edit here, this computer's or another's.
  int get _seenTs => _lastTs ??= _db.select('SELECT MAX(ts) FROM sync_reg').first.columnAt(0) as int? ?? 0;

  /// The last number this computer gave one of its edits, or another
  /// computer has seen of it (lost here since).
  int get _seenSeq => _lastSeq ??= () {
    final r = _db.select(
      "SELECT MAX(CASE WHEN origin = ?1 THEN seq END), MAX(json_extract(vv, '\$.\"' || ?1 || '\"')) FROM sync_reg",
      [me],
    ).first;
    return max(r.columnAt(0) as int? ?? 0, r.columnAt(1) as int? ?? 0);
  }();

  /// When an edit was made: [at] (when the row was written, by this
  /// computer's clock), or later if a register is newer, so each edit sorts
  /// after everything this computer had seen when it was made; but never
  /// past now, so one wrong clock's times (this computer's own, before
  /// they were put right) don't carry on into later edits.
  int _tick([int? at]) {
    final now = _now();
    final ts = min(max(at == null ? now : min(at + offset, now), _seenTs + 1), now);
    _lastTs = max(_seenTs, ts);
    return ts;
  }

  /// This computer's number for its next edit: always higher than the
  /// last, which says which of its edits came after which (in the version
  /// per computer) and what's been sent, whatever the clock does.
  int _nextSeq() => _lastSeq = max(_seenSeq + 1, _now());

  // Rows as registers

  static const _present = '_';

  /// Kinds whose rows can be removed; the others always exist, blank.
  static const _removable = {'month_habit', 'todo', 'exercise', 'training_set', 'todo_repeat'};

  /// What each kind of row keeps, by field, with the database version that
  /// first kept it. An older version keeps another computer's edit of a
  /// field it doesn't have only as a register, so upgrading takes those in
  /// rather than sending the blanks it had (see [_upgrade]). A field added
  /// later goes here with the version that adds it.
  static const fields = <String, Map<String, int>>{
    'habit_month': {'initialized': 9},
    'todo_history': {'snapshot': 9},
    'month_habit': {_present: 8, 'name': 8, 'position': 8, 'note': 8, 'added_on': 14, 'days': 18},
    'entry': {'status': 8, 'note': 8},
    'todo': {
      _present: 8,
      'scope': 8,
      'period': 8,
      'text': 8,
      'done': 8,
      'carried': 8,
      'since': 8,
      'due_date': 10,
      'return_to_tomorrow': 11,
      'return_scope': 12,
      'defer_promotion_day': 12,
      'subtasks': 13,
      'done_at': 17,
      'due_time': 29,
      'category': 29,
      'position': 30,
      'reminders': 31,
    },
    'journal': {'text': 8},
    'sleep_note': {'note': 8},
    'setting': {'value': 8},
    'exercise': {_present: 22, 'name': 22, 'muscle': 22, 'bodyweight': 22},
    'training_set': {_present: 22, 'day': 22, 'exercise': 22, 'position': 22, 'weight': 22, 'reps': 22},
    'todo_repeat': {
      _present: 28,
      'text': 28,
      'rule': 28,
      'start': 28,
      'until': 28,
      'time': 29,
      'category': 29,
      'reminders': 31,
      'subtasks': 32,
    },
  };

  /// A to-do's fields that say where it is. A change of whether it's done,
  /// its list or its day sends them all, so its place goes as a whole: a
  /// tick on one computer and a move on the other can't mix, and the day a
  /// day start had moved it to here goes with a tick.
  static const _place = [
    'scope',
    'period',
    'carried',
    'done',
    'done_at',
    'return_to_tomorrow',
    'return_scope',
    'defer_promotion_day',
  ];
  static const _moves = {'scope', 'period', 'done'};

  static (String, String) _split(String rowkey) {
    final i = rowkey.indexOf('/');
    return (rowkey.substring(0, i), rowkey.substring(i + 1));
  }

  static (int, int) _month(String key) {
    final [y, m] = key.split('-');
    return (int.parse(y), int.parse(m));
  }

  /// The row's fields as they are now, with [_present] for removable kinds.
  Map<String, Object?> _read(String kind, String rowkey) {
    Map<String, Object?>? row(String sql, List<Object?> args) {
      final r = _db.select(sql, args);
      return r.isEmpty ? null : Map.of(r.first);
    }

    final Map<String, Object?>? fields;
    switch (kind) {
      case 'habit_month':
        final (y, m) = _month(rowkey);
        return {'initialized': store.hasMonth(y, m)};
      case 'todo_history':
        final (day, uid) = _split(rowkey);
        return {
          'snapshot': row('SELECT snapshot FROM todo_history WHERE uid = ? AND day = ?', [uid, day])?['snapshot'],
        };
      case 'month_habit':
        final (month, uid) = _split(rowkey);
        final (y, m) = _month(month);
        fields = row(
          'SELECT name, position, note, added_on, days FROM month_habits JOIN habits h ON h.id = habit_id '
          'WHERE year = ? AND month = ? AND h.uid = ?',
          [y, m, uid],
        );
      case 'entry':
        final (day, uid) = _split(rowkey);
        return row('SELECT status, note FROM entries JOIN habits h ON h.id = habit_id WHERE day = ? AND h.uid = ?', [
              day,
              uid,
            ]) ??
            {'status': 0, 'note': null};
      case 'todo':
        fields = row(
          'SELECT scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks, done_at, due_time, category, position, reminders FROM todos WHERE uid = ?',
          [rowkey],
        );
      case 'journal':
        return {
          'text': row('SELECT text FROM journal WHERE day = ?', [rowkey])?['text'] ?? '',
        };
      case 'sleep_note':
        final (month, item) = _split(rowkey);
        final (y, m) = _month(month);
        return {
          'note': row('SELECT note FROM sleep_notes WHERE year = ? AND month = ? AND item = ?', [y, m, item])?['note'],
        };
      case 'setting':
        return {
          'value': row('SELECT value FROM settings WHERE key = ?', [rowkey])?['value'],
        };
      case 'exercise':
        fields = row('SELECT name, muscle, bodyweight FROM exercises WHERE uid = ?', [rowkey]);
      case 'training_set':
        fields = row('SELECT day, exercise, position, weight, reps FROM training_sets WHERE uid = ?', [rowkey]);
      case 'todo_repeat':
        fields = row(
          'SELECT text, rule, start, until, time, category, reminders, subtasks FROM todo_repeats WHERE uid = ?',
          [rowkey],
        );
      default:
        // From a newer version: kept as registers until this one is updated.
        return const {};
    }
    return fields == null ? {_present: false} : {...fields, _present: true};
  }

  int _habit(String uid) {
    _db.execute('INSERT OR IGNORE INTO habits (uid) VALUES (?)', [uid]);
    return _db.select('SELECT id FROM habits WHERE uid = ?', [uid]).first['id'] as int;
  }

  /// What a row of a kind that can be removed can't be without: until it's
  /// come (in a file not read yet), an edit of it waits, the row not there.
  static const _made = {
    'todo': 'since',
    'month_habit': 'name',
    'exercise': 'name',
    'training_set': 'exercise',
    'todo_repeat': 'start',
  };

  /// Makes the row match [f], its fields from the registers.
  void _write(String kind, String rowkey, Map<String, Object?> f) {
    final gone = _removable.contains(kind) && (f[_present] != true || f[_made[kind]] == null);
    switch (kind) {
      case 'habit_month':
        final (y, m) = _month(rowkey);
        if (f['initialized'] == true) store.initializeMonth(y, m);
      case 'todo_history':
        final (day, uid) = _split(rowkey);
        if (f['snapshot'] == null) {
          _db.execute('DELETE FROM todo_history WHERE uid = ? AND day = ?', [uid, day]);
        } else {
          _db.execute(
            'INSERT INTO todo_history VALUES (?, ?, ?) ON CONFLICT (uid, day) DO UPDATE SET snapshot = excluded.snapshot',
            [uid, day, f['snapshot']],
          );
        }
      case 'month_habit':
        final (month, uid) = _split(rowkey);
        final (y, m) = _month(month);
        store.initializeMonth(y, m);
        final id = _habit(uid);
        if (gone) {
          _db.execute('DELETE FROM month_habits WHERE year = ? AND month = ? AND habit_id = ?', [y, m, id]);
        } else {
          _db.execute(
            'INSERT INTO month_habits (year, month, habit_id, name, position, note, added_on, days) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (year, month, habit_id) DO UPDATE SET name = excluded.name, position = excluded.position, '
            'note = excluded.note, added_on = excluded.added_on, days = excluded.days',
            [y, m, id, f['name'] ?? '', f['position'] ?? 0, f['note'], f['added_on'], f['days']],
          );
        }
      case 'entry':
        final (day, uid) = _split(rowkey);
        final id = _habit(uid);
        final status = f['status'] as int? ?? 0;
        if (status == 0) {
          _db.execute('DELETE FROM entries WHERE day = ? AND habit_id = ?', [day, id]);
        } else {
          _db.execute(
            'INSERT INTO entries (day, habit_id, status, note) VALUES (?, ?, ?, ?) '
            'ON CONFLICT (day, habit_id) DO UPDATE SET status = excluded.status, note = excluded.note',
            [day, id, status, f['note']],
          );
        }
      case 'todo':
        if (gone) {
          _db.execute('DELETE FROM todos WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO todos (uid, scope, period, text, done, carried, since, due_date, return_to_tomorrow, return_scope, defer_promotion_day, subtasks, done_at, due_time, category, position, reminders) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET scope = excluded.scope, period = excluded.period, text = excluded.text, '
            'done = excluded.done, carried = excluded.carried, since = excluded.since, due_date = excluded.due_date, '
            'return_to_tomorrow = excluded.return_to_tomorrow, return_scope = excluded.return_scope, '
            'defer_promotion_day = excluded.defer_promotion_day, subtasks = excluded.subtasks, done_at = excluded.done_at, '
            'due_time = excluded.due_time, category = excluded.category, position = excluded.position, '
            'reminders = excluded.reminders',
            [
              rowkey,
              f['scope'] ?? 'today',
              f['period'] ?? f['since'] ?? '',
              f['text'] ?? '',
              f['done'] ?? 0,
              f['carried'] ?? 0,
              f['since'] ?? f['period'] ?? '',
              f['due_date'],
              f['return_to_tomorrow'] ?? 0,
              f['return_scope'] ?? (f['return_to_tomorrow'] == 1 ? 'tomorrow' : null),
              f['defer_promotion_day'],
              f['subtasks'] ?? '[]',
              f['done_at'],
              f['due_time'],
              f['category'],
              f['position'],
              f['reminders'],
            ],
          );
        }
      case 'journal':
        store.setJournal(rowkey, f['text'] as String? ?? '');
      case 'sleep_note':
        final (month, item) = _split(rowkey);
        final (y, m) = _month(month);
        final note = f['note'] as String?;
        if (note == null) {
          _db.execute('DELETE FROM sleep_notes WHERE year = ? AND month = ? AND item = ?', [y, m, item]);
        } else {
          _db.execute(
            'INSERT INTO sleep_notes (year, month, item, note) VALUES (?, ?, ?, ?) '
            'ON CONFLICT (year, month, item) DO UPDATE SET note = excluded.note',
            [y, m, item, note],
          );
        }
      case 'setting':
        final value = f['value'] as String?;
        if (value == null) {
          _db.execute('DELETE FROM settings WHERE key = ?', [rowkey]);
        } else {
          store.setSetting(rowkey, value);
        }
      case 'exercise':
        if (gone) {
          _db.execute('DELETE FROM exercises WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO exercises (uid, name, muscle, bodyweight) VALUES (?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET name = excluded.name, muscle = excluded.muscle, bodyweight = excluded.bodyweight',
            [rowkey, f['name'] ?? '', f['muscle'] ?? 'chest', f['bodyweight'] ?? 0],
          );
        }
      case 'training_set':
        if (gone) {
          _db.execute('DELETE FROM training_sets WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO training_sets (uid, day, exercise, position, weight, reps) VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET day = excluded.day, exercise = excluded.exercise, '
            'position = excluded.position, weight = excluded.weight, reps = excluded.reps',
            [rowkey, f['day'] ?? '', f['exercise'] ?? '', f['position'] ?? 0, f['weight'], f['reps'] ?? 0],
          );
        }
      case 'todo_repeat':
        if (gone || RepeatRule.decode(f['rule'] as String? ?? '') == null) {
          _db.execute('DELETE FROM todo_repeats WHERE uid = ?', [rowkey]);
        } else {
          _db.execute(
            'INSERT INTO todo_repeats (uid, text, rule, start, until, time, category, reminders, subtasks) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (uid) DO UPDATE SET text = excluded.text, rule = excluded.rule, '
            'start = excluded.start, until = excluded.until, time = excluded.time, category = excluded.category, '
            'reminders = excluded.reminders, subtasks = excluded.subtasks',
            [
              rowkey,
              f['text'] ?? '',
              f['rule'],
              f['start'],
              f['until'],
              f['time'],
              f['category'],
              f['reminders'],
              f['subtasks'],
            ],
          );
        }
    }
  }

  static bool _blank(Object? v) => v == null || v == false || v == 0 || v == '';

  // Registers

  _Reg? _reg(String kind, String rowkey, String field) {
    final r = _db.select('SELECT * FROM sync_reg WHERE kind = ? AND rowkey = ? AND field = ?', [kind, rowkey, field]);
    return r.isEmpty ? null : _Reg.fromRow(r.first);
  }

  void _put(_Reg r) => _db.execute(
    'INSERT OR REPLACE INTO sync_reg (kind, rowkey, field, value, ts, origin, vv, journal_versions, seq) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    r.row,
  );

  /// What a day start left in the row's fields, as [_markLocal] marked it.
  Map<String, String> _marks(String kind, String rowkey) => {
    for (final r in _db.select('SELECT field, value FROM sync_local WHERE kind = ? AND rowkey = ?', [kind, rowkey]))
      r['field'] as String: r['value'] as String,
  };

  /// Turns rows written here since last time into edits of this computer.
  void flush() => _flush();

  /// [weak]: filled in, not edited, so they don't count as having seen
  /// anything: an edit another computer made that this one hadn't heard of
  /// wins over them. [skip]: fields left as they are.
  void _flush({bool weak = false, Set<(String, String)> skip = const {}}) {
    final dirty = _db.select('SELECT kind, rowkey, at FROM sync_dirty ORDER BY at');
    if (dirty.isEmpty) return;
    store.transaction(() {
      for (final d in dirty) {
        final kind = d['kind'] as String, rowkey = d['rowkey'] as String;
        final now = _read(kind, rowkey), local = _marks(kind, rowkey);
        final changed = <String, Object?>{};
        for (final MapEntry(key: field, value: v) in now.entries) {
          if (skip.contains((kind, field))) continue;
          final value = jsonEncode(v);
          if (local[field] case final left?) {
            // Set by a day start: an edit once it's changed from that, even
            // back to what sync has (moved back to the list it came from).
            if (left == value) continue;
          } else {
            final old = _reg(kind, rowkey, field);
            if (old == null ? _blank(v) : old.value == value) continue;
          }
          changed[field] = v;
        }
        if (changed.isEmpty) continue;
        if (local.isNotEmpty) _movedEdited = true;
        if (kind == 'todo' && changed.keys.any(_moves.contains)) {
          for (final field in _place) {
            changed.putIfAbsent(field, () => now[field]);
          }
        }
        // An edit says the row is there, so one made after it was deleted
        // elsewhere brings it back; the later of the two wins.
        if (_removable.contains(kind) && now[_present] == true) changed[_present] = true;
        final ts = _tick(d['at'] as int), seq = _nextSeq();
        for (final MapEntry(key: field, value: v) in changed.entries) {
          final old = _reg(kind, rowkey, field);
          final vv = weak ? {...?old?.vv} : {...?old?.vv, me: seq};
          _put(
            _Reg(
              kind,
              rowkey,
              field,
              jsonEncode(v),
              ts,
              me,
              vv,
              kind == 'journal' && field == 'text' && !weak ? [_JournalVersion(me, ts, v as String, vv)] : null,
              seq,
            ),
          );
          if (local.containsKey(field)) {
            _db.execute('DELETE FROM sync_local WHERE kind = ? AND rowkey = ? AND field = ?', [kind, rowkey, field]);
          }
        }
      }
      _db.execute('DELETE FROM sync_dirty');
    });
  }

  /// Whether this computer has synced. Until it has, what the app does by
  /// itself is left to its first sign-in, which takes everything as it is.
  bool get _engaged => _db.select('SELECT 1 FROM sync_reg LIMIT 1').isNotEmpty;

  /// Before the app writes by itself: what was edited until now goes as
  /// edits, with their own times. The first day start of a day (or the
  /// next after an edit of something one had moved) then works from the
  /// edits alone: what the ones before moved here goes back to how sync has
  /// it, so this computer moves things on just as the others do.
  @override
  void before({required bool local, String? day}) {
    if (!_engaged) return;
    flush();
    if (local && (day != _startedFor || _movedEdited)) {
      _resetLocal();
      _startedFor = day;
      _movedEdited = false;
    }
  }

  String? _startedFor;
  var _movedEdited = false;

  void _resetLocal() {
    final rows = {
      for (final r in _db.select('SELECT DISTINCT kind, rowkey FROM sync_local'))
        (r['kind'] as String, r['rowkey'] as String),
    };
    if (rows.isEmpty) return;
    store.transaction(() {
      for (final (kind, rowkey) in rows) {
        final synced = _fields(kind, rowkey);
        if (synced.isNotEmpty) {
          _write(kind, rowkey, synced);
        } else if (kind == 'todo_history') {
          final (day, uid) = _split(rowkey);
          _db.execute('DELETE FROM todo_history WHERE uid = ? AND day = ?', [uid, day]);
        }
      }
      _db.execute('DELETE FROM sync_local');
      _db.execute('DELETE FROM sync_dirty');
    });
  }

  @override
  void after({required bool local}) {
    if (!_engaged) return;
    if (local) {
      _markLocal();
    } else {
      _flush(weak: true);
    }
  }

  /// Marks what the rows written since [before] now hold, where it differs
  /// from what sync has, as this computer's own, never sent; any edit to
  /// those fields later is.
  void _markLocal() {
    store.transaction(() {
      for (final d in _db.select('SELECT kind, rowkey FROM sync_dirty')) {
        final kind = d['kind'] as String, rowkey = d['rowkey'] as String;
        final synced = {
          for (final r in _db.select('SELECT field, value FROM sync_reg WHERE kind = ? AND rowkey = ?', [kind, rowkey]))
            r['field'] as String: r['value'] as String,
        };
        _db.execute('DELETE FROM sync_local WHERE kind = ? AND rowkey = ?', [kind, rowkey]);
        for (final MapEntry(key: field, value: v) in _read(kind, rowkey).entries) {
          final value = jsonEncode(v), old = synced[field];
          if (old == null ? _blank(v) : old == value) continue;
          _db.execute('INSERT INTO sync_local VALUES (?, ?, ?, ?)', [kind, rowkey, field, value]);
        }
      }
      _db.execute('DELETE FROM sync_dirty');
    });
  }

  /// After an upgrade from [from]: what this version keeps that that one
  /// couldn't is taken in from the registers, rather than its blanks sent.
  void _upgrade(int from) {
    if (!_engaged) return;
    final added = {
      for (final MapEntry(key: kind, value: kept) in fields.entries)
        for (final MapEntry(key: field, value: since) in kept.entries)
          if (since > from) (kind, field),
    };
    store.transaction(() {
      _flush(skip: added);
      final rows = {
        for (final (kind, field) in added)
          for (final r in _db.select('SELECT rowkey FROM sync_reg WHERE kind = ? AND field = ?', [kind, field]))
            (kind, r['rowkey'] as String),
      };
      for (final (kind, rowkey) in rows) {
        _write(kind, rowkey, _fields(kind, rowkey));
        _db.execute('DELETE FROM sync_local WHERE kind = ? AND rowkey = ?', [kind, rowkey]);
      }
      _db.execute('DELETE FROM sync_dirty');
    });
  }

  /// The row as sync has it, field by field.
  Map<String, Object?> _fields(String kind, String rowkey) => {
    for (final r in _db.select('SELECT field, value FROM sync_reg WHERE kind = ? AND rowkey = ?', [kind, rowkey]))
      r['field'] as String: jsonDecode(r['value'] as String),
  };

  /// Makes every row an edit of this computer, as it is: the first computer
  /// to sync, or one moving its data to another account.
  void claimAll() {
    _db.execute('DELETE FROM sync_local');
    store.markAllChanged();
    flush();
  }

  /// The user explicitly chose to transfer local data to another account.
  void forgetSync() {
    store.transaction(() {
      _db.execute('DELETE FROM sync_reg');
      _db.execute('DELETE FROM sync_seen');
      _db.execute('DELETE FROM sync_dirty');
      _db.execute('DELETE FROM sync_local');
    });
    _lastTs = _lastSeq = null;
  }

  /// Takes as this computer's own the edits under another id newer than
  /// anything of that id's in Drive ([sent]): its own, from before it had
  /// this id (sync's settings lost, the database kept), which never went.
  void adoptUnsent(Map<String, int> sent) {
    store.transaction(() {
      for (final r in _db.select('SELECT DISTINCT origin FROM sync_reg WHERE origin != ?', [me])) {
        final origin = r['origin'] as String;
        _db.execute('UPDATE sync_reg SET origin = ?, seq = MAX(seq, ts) WHERE origin = ? AND ts > ?', [
          me,
          origin,
          sent[origin] ?? 0,
        ]);
      }
    });
    _lastSeq = null;
  }

  /// The computers with edits of things this version doesn't keep: they
  /// show once it's updated.
  Set<String> get newerOrigins => {
    for (final r in _db.select('SELECT DISTINCT kind, field, origin FROM sync_reg'))
      if (fields[r['kind']]?.containsKey(r['field']) != true) r['origin'] as String,
  };

  /// Clears this computer's rows and registers, to take another's whole
  /// history in their place. The sleep schedule's rituals stay: they're
  /// the same everywhere.
  ///
  /// Returns the journal days that were here, to remove their files.
  /// Reads the latest edit numbers again, after a rolled-back merge.
  void forgetCounts() => _lastTs = _lastSeq = null;

  List<String> clearForJoining() {
    final days = [for (final r in _db.select('SELECT day FROM journal')) r['day'] as String];
    store.transaction(() {
      _db.execute('DELETE FROM month_habits');
      _db.execute('DELETE FROM habit_months');
      _db.execute('DELETE FROM todo_history');
      _db.execute('DELETE FROM entries');
      _db.execute('DELETE FROM todos');
      _db.execute('DELETE FROM journal');
      _db.execute('DELETE FROM sleep_notes');
      _db.execute('DELETE FROM exercises');
      _db.execute('DELETE FROM training_sets');
      _db.execute('DELETE FROM todo_repeats');
      _db.execute('DELETE FROM settings WHERE key IN (${Store.syncedSettings.map((k) => "'$k'").join(', ')})');
      _db.execute('DELETE FROM habits WHERE id NOT IN (SELECT habit_id FROM sleep_habits)');
      _db.execute('DELETE FROM sync_reg');
      _db.execute('DELETE FROM sync_seen');
      _db.execute('DELETE FROM sync_dirty');
      _db.execute('DELETE FROM sync_local');
    });
    _lastTs = _lastSeq = null;
    return days;
  }

  /// This computer's edits, grouped by the day (UTC) they were made, for
  /// every day with an edit after [since] (one of [latest]'s numbers).
  Map<String, List<List<Object?>>> changesSince(int since) {
    final days = [
      for (final r in _db.select(
        "SELECT DISTINCT date(ts / 1000, 'unixepoch') AS d FROM sync_reg WHERE origin = ? AND seq > ?",
        [me, since],
      ))
        r['d'] as String,
    ];
    return {
      for (final day in days)
        day: [
          for (final r in _db.select(
            "SELECT * FROM sync_reg WHERE origin = ? AND date(ts / 1000, 'unixepoch') = ? ORDER BY kind, rowkey, field",
            [me, day],
          ))
            _Reg.fromRow(r).toJson(),
        ],
    };
  }

  /// For each journal day, the computer that made its latest edit: when
  /// both wrote at once, whichever wrote later. The same on every computer
  /// once they've synced.
  Map<String, String> journalWriters() => {
    for (final r in _db.select(
      "SELECT rowkey, origin, ts, journal_versions FROM sync_reg WHERE kind = 'journal' AND field = 'text'",
    ))
      r['rowkey'] as String: r['journal_versions'] == null
          ? r['origin'] as String
          : ((jsonDecode(r['journal_versions'] as String) as List)
                    .map((v) => _JournalVersion.fromJson(v as List))
                    .fold<_JournalVersion?>(
                      null,
                      (a, b) => a == null || (b.ts, b.origin).compareTo(a.ts, a.origin) > 0 ? b : a,
                    )
                    ?.origin ??
                r['origin'] as String),
  };

  /// The number of this computer's latest edit, to send what came after.
  int get latest => _db.select('SELECT MAX(seq) FROM sync_reg WHERE origin = ?', [me]).first.columnAt(0) as int? ?? 0;

  /// Merges other computers' registers in, and brings the rows they touch
  /// up to date.
  Incoming mergeAll(Iterable<(Iterable<List<Object?>>, String)> batches) {
    flush(); // so edits made here count in the comparison
    final touched = <(String, String)>{};
    final names = <String>{};
    final failed = <int>{};
    _keptBoth.clear();
    store.transaction(() {
      for (final (i, (regs, from)) in batches.indexed) {
        final kept = {..._keptBoth};
        try {
          // A file at a time, so one this version can't take in is left as
          // it was, without holding up the rest.
          store.transaction(() {
            final rows = <(String, String)>{};
            for (final json in regs) {
              final theirs = _Reg.fromJson(json);
              _lastTs = max(_seenTs, theirs.ts);
              _lastSeq = max(_seenSeq, theirs.vv[me] ?? 0);
              final ours = _reg(theirs.kind, theirs.rowkey, theirs.field);
              final merged = ours == null ? theirs : _resolve(ours, theirs);
              if (merged == null) continue;
              _put(merged);
              if (ours?.value != merged.value) rows.add((theirs.kind, theirs.rowkey));
            }
            for (final (kind, rowkey) in rows) {
              _write(kind, rowkey, _fields(kind, rowkey));
              _db.execute('DELETE FROM sync_local WHERE kind = ? AND rowkey = ?', [kind, rowkey]);
            }
            touched.addAll(rows);
            // Unless it's this computer's own, read back after its database
            // lost them.
            if (rows.isNotEmpty && from != me) names.add(from);
          });
        } on Object {
          failed.add(i);
          _keptBoth
            ..clear()
            ..addAll(kept);
        }
      }
      // Day-start moves are never sent (see Store.startDay), so a task
      // another computer changed goes back to how the edits left it, and
      // the app moves it on again from there.
      final tasks = {
        for (final (kind, rowkey) in touched)
          if (kind == 'todo') rowkey else if (kind == 'todo_history') _split(rowkey).$2,
      };
      for (final uid in tasks) {
        for (final r in _db.select('SELECT day FROM todo_history WHERE uid = ?', [uid])) {
          final rowkey = '${r['day']}/$uid', synced = _fields('todo_history', rowkey);
          if (synced.isEmpty) {
            _db.execute('DELETE FROM todo_history WHERE uid = ? AND day = ?', [uid, r['day']]);
          } else {
            _write('todo_history', rowkey, synced);
          }
        }
        _db.execute(
          "DELETE FROM sync_local WHERE kind = 'todo' AND rowkey = ?1 "
          "OR kind = 'todo_history' AND substr(rowkey, instr(rowkey, '/') + 1) = ?1",
          [uid],
        );
        final task = _fields('todo', uid);
        if (task.isNotEmpty) _write('todo', uid, task);
      }
      // Writing them marked them changed; they match their registers.
      _db.execute('DELETE FROM sync_dirty');
    });
    return Incoming(touched, names, {..._keptBoth}, failed);
  }

  final _keptBoth = <String>{};

  /// What a register becomes, given another computer's copy of it; null to
  /// keep ours as it is.
  _Reg? _resolve(_Reg ours, _Reg theirs) {
    if (ours.kind == 'journal' && ours.field == 'text') return _resolveJournal(ours, theirs);
    final order = _compare(ours.vv, theirs.vv);
    if (order == 1) return null; // ours has seen theirs
    if (order == -1) return theirs; // theirs has seen ours
    // Neither saw the other, or both filled in the same thing (see [Store.weak]):
    // the later wins.
    final win = (ours.ts, ours.origin).compareTo(theirs.ts, theirs.origin) >= 0 ? ours : theirs;
    final vv = _maxVv(ours.vv, theirs.vv);
    // The same value: it stays, with the later one's time.
    final value = ours.value == theirs.value ? ours.value : win.value;
    if (value == ours.value && win == ours && _compare(ours.vv, vv) == 0) return null;
    return _Reg(ours.kind, ours.rowkey, ours.field, value, win.ts, win.origin, vv, null, win == ours ? ours.seq : 0);
  }

  _Reg? _resolveJournal(_Reg ours, _Reg theirs) {
    final order = _compare(ours.vv, theirs.vv);
    if (order == 1) return null;
    if (order == -1) return theirs;
    List<_JournalVersion> versions(_Reg r) =>
        r.journalVersions ?? [_JournalVersion(r.origin, r.ts, jsonDecode(r.value) as String, r.vv)];
    final all = <String, _JournalVersion>{};
    for (final v in [...versions(ours), ...versions(theirs)]) {
      all[jsonEncode(v.toJson())] = v;
    }
    // Retain the maximal concurrent revisions, rather than concatenated
    // merge results. Union + causal pruning is independent of delivery order.
    final kept = all.values.where((v) => !all.values.any((other) => _compare(other.vv, v.vv) == 1)).toList()
      ..sort((a, b) {
        final order = (a.ts, a.origin).compareTo(b.ts, b.origin);
        return order == 0 ? a.text.compareTo(b.text) : order;
      });
    final texts = {
      for (final v in kept)
        if (v.text.trim().isNotEmpty) v.text,
    };
    final value = jsonEncode(texts.join(Store.journalBreak));
    final vv = _maxVv(ours.vv, theirs.vv);
    final sameVersions =
        jsonEncode(versions(ours).map((v) => v.toJson()).toList()) == jsonEncode(kept.map((v) => v.toJson()).toList());
    if (ours.value == value && _compare(ours.vv, vv) == 0 && sameVersions) return null;
    if (order == 2 && texts.length > 1 && ours.value != value) _keptBoth.add(ours.rowkey);
    return _Reg(ours.kind, ours.rowkey, ours.field, value, _tick(), me, vv, kept, _nextSeq());
  }

  /// 0 when equal, 1 when [a] has seen all of [b], -1 when [b] has seen all
  /// of [a], 2 when neither.
  static int _compare(Map<String, int> a, Map<String, int> b) {
    var aAhead = false, bAhead = false;
    for (final k in {...a.keys, ...b.keys}) {
      final x = a[k] ?? 0, y = b[k] ?? 0;
      if (x > y) aAhead = true;
      if (y > x) bAhead = true;
    }
    return aAhead && bAhead
        ? 2
        : aAhead
        ? 1
        : bAhead
        ? -1
        : 0;
  }

  static Map<String, int> _maxVv(Map<String, int> a, Map<String, int> b) => {
    for (final k in {...a.keys, ...b.keys}) k: max(a[k] ?? 0, b[k] ?? 0),
  };
}
