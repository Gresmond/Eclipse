part of '../app_state.dart';

/// Something taken away that can be put back.
class Removal {
  Removal._(this.label, this._before);

  /// What the undo card says: 'Removed “Buy milk”'.
  final String label;
  final List<RowsBefore> _before;
}

/// Undo for removing a task, ritual or training set: the last few removals, and the
/// latest one for the undo card to name until it's put back or the card
/// times out.
mixin _Undo on ChangeNotifier {
  Store get store;

  /// After rows of [tables] were put back.
  void _reloadAfterUndo(Set<String> tables, List<RowsBefore> undone);
  void _prepareUndo();

  static const _kept = 3;

  final _redone = <Removal>[];
  bool get canRedo => _redone.isNotEmpty;

  final _removals = <Removal>[];

  /// The removal the undo card names, while it shows.
  Removal? shownRemoval;

  /// Collecting removals that are one action, like a task and the times
  /// after it.
  List<Removal>? _together;

  bool get canUndo => _removals.isNotEmpty;

  /// Runs [remove] as one removal, undone together.
  void removeTogether(void Function() remove) {
    final together = _together = [];
    try {
      remove();
    } finally {
      _together = null;
    }
    if (together.isEmpty) return;
    _remember(Removal._(together.last.label, [for (final r in together) ...r._before]));
  }

  /// Notes a removal of the rows [before], about to change.
  void _undoable(String label, List<RowsBefore> before) {
    final removal = Removal._(label, before);
    final together = _together;
    together == null ? _remember(removal, notify: false) : together.add(removal);
  }

  void _remember(Removal removal, {bool notify = true}) {
    _redone.clear();
    _removals.add(removal);
    if (_removals.length > _kept) _removals.removeAt(0);
    shownRemoval = removal;
    if (notify) notifyListeners();
  }

  /// Puts back the latest removal.
  void undo() {
    if (_removals.isEmpty) return;
    _apply(_removals, _redone);
  }

  void redo() {
    if (_redone.isNotEmpty) _apply(_redone, _removals);
  }

  void _apply(List<Removal> source, List<Removal> destination) {
    _prepareUndo();
    final action = source.last;
    final inverse = store.transaction(() {
      final snapshots = <RowsBefore>[];
      for (final row in action._before.reversed) {
        snapshots.add(store.rowsBefore(row.table, row.key, row.where, row.args));
        store.putBack([row]);
      }
      return snapshots;
    });
    source.removeLast();
    destination.add(Removal._(action.label, inverse));
    shownRemoval = null;
    _reloadAfterUndo({for (final b in inverse) b.table}, action._before);
  }

  /// The card naming [removal] has had its time.
  void hideUndoCard(Removal removal) {
    if (!identical(shownRemoval, removal)) return;
    shownRemoval = null;
    notifyListeners();
  }

  /// A new day: what was removed yesterday stays removed.
  void _forgetRemovals() {
    _redone.clear();
    _removals.clear();
    shownRemoval = null;
  }
}
