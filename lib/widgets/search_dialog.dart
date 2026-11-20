import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'todo_panel.dart' show addTaskAnywhere;

import '../app_state.dart';
import '../data/search.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart';
import 'corner_card.dart' show briefBadgeInk;
import 'fade_menu.dart';
import '../theme/pixels.dart';

/// Every task and journal entry, any day, found as you type; a result
/// opens its day and lights it there.
class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key});

  /// The results' box keeps one height, so the dialog doesn't jump as you
  /// type.
  static const height = 420.0;

  /// Results drawn at most; more words narrow it.
  static const shown = 100;

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final _controller = TextEditingController();
  late final _state = AppScope.read(context);
  late final _focus = FocusNode(
    onKeyEvent: (_, event) {
      if (event is KeyUpEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (event is KeyDownEvent) _activate(_selected);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _step(event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );
  late final SearchIndex _index;
  List<SearchHit> _hits = const [];
  List<String> _words = const [];

  @override
  void initState() {
    super.initState();
    _state.saveDrafts();
    _index = _state.searchIndex;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String query) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _selected = 0;
      _rowKeys.clear();
      _words = SearchIndex.words(query);
      _hits = _index.search(query);
    });
  }

  /// Empties the field, keeping it focused to type again.
  void _clear() {
    _controller.clear();
    _search('');
    _focus.requestFocus();
  }

  int _selected = 0;
  final _scroll = ScrollController();
  final _rowKeys = <int, GlobalKey>{};
  GlobalKey _keyFor(int i) => _rowKeys.putIfAbsent(i, () => GlobalKey());

  List<(String, VoidCallback)> get _commands {
    final query = _controller.text.trim().toLowerCase();
    final day = DateTime.tryParse(query);
    return [
      if (day != null && dateKey(day) == query && !day.isAfter(_state.today))
        ('Go to ${dateKey(day)}', () => _state.showDay(day)),
      ...<(String, VoidCallback)>[
        (
          'Add task',
          () {
            if (appNavigator.currentContext case final ctx?) addTaskAnywhere(ctx);
          },
        ),
        ('Show Today', _state.showToday),
        (
          'Show month',
          () {
            if (_state.viewYear != _state.today.year) _state.shiftYear(_state.today.year - _state.viewYear);
            _state.showMonth(_state.today.month);
          },
        ),
        ('Show year', _state.showYear),
        (
          'Show Training',
          () {
            if (!_state.showingTraining) _state.toggleTraining();
          },
        ),
        (
          'Toggle theme',
          () {
            if (kIsWeb && _state.followNightLight) _state.setFollowNightLight(false);
            _state.setTheme(
              partnerOf(_state.themeName, dark: paletteNamed(_state.themeName).brightness == Brightness.light).name,
            );
          },
        ),
        if (_state.canUndo) ('Undo', _state.undo),
        if (_state.canRedo) ('Redo', _state.redo),
      ].where((command) => command.$1.toLowerCase().contains(query)),
    ];
  }

  void _activate(int index) {
    final commands = _commands;
    if (index < commands.length) {
      Navigator.pop(context);
      commands[index].$2();
    } else if (index - commands.length < _hits.length) {
      _open(_hits[index - commands.length]);
    }
  }

  double get _rowHeight => 40 + 3 * MediaQuery.textScalerOf(context).scale(16);

  void _step(int offset) {
    final count = _commands.length + _hits.length.clamp(0, SearchDialog.shown);
    if (count == 0) return;
    setState(() => _selected = (_selected + offset).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_rowKeys[_selected]?.currentContext case final rowContext?) {
        Scrollable.ensureVisible(rowContext, alignment: offset > 0 ? 1.0 : 0.0);
      } else {
        final target = _selected * _rowHeight;
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  void _open(SearchHit hit) {
    Navigator.pop(context);
    if (hit.kind == 'training') {
      if (!_state.showingTraining) _state.toggleTraining();
      _state.training.showDay(hit.day == _state.today ? null : hit.day);
    } else if (hit.kind == 'ritual') {
      _state.showToday();
      _state.shiftYear(hit.day.year - _state.today.year);
      _state.showMonth(hit.day.month);
    } else {
      _state.showFound(hit.day, hit.target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hits = _hits, words = _words, commands = _commands;
    final field = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.only(left: 16, right: 8),
          decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: _search,
                  onSubmitted: (_) => _activate(_selected),
                  cursorColor: p.ink,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search or run a command',
                    hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_controller.text.isNotEmpty)
                TextFieldTapRegion(
                  child: PixelTooltip(
                    message: 'Clear',
                    child: IconButton(
                      onPressed: _clear,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                      padding: EdgeInsets.zero,
                      style: ButtonStyle(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
                        shape: const WidgetStatePropertyAll(CircleBorder()),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.hovered)
                              ? p.empty.withValues(alpha: 0.8)
                              : Colors.transparent,
                        ),
                        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                      ),
                      icon: Icon(Icons.close_rounded, size: Scale.dismissIcon, color: p.inkMuted),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: SearchDialog.height,
          child: DecoratedBox(
            decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: hits.isEmpty && commands.isEmpty
                  ? _message(p, curlyQuotes('Nothing matches "${_controller.text.trim()}".'))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: commands.length + hits.length.clamp(0, SearchDialog.shown),
                      itemBuilder: (context, i) => KeyedSubtree(
                        key: _keyFor(i),
                        child: Material(
                          color: i == _selected ? p.empty : Colors.transparent,
                          child: i < commands.length
                              ? FadeMenuRow(
                                  height: 46,
                                  onTap: () => _activate(i),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      commands[i].$1,
                                      style: TextStyle(
                                        fontFamily: Fonts.ui,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: p.ink,
                                      ),
                                    ),
                                  ),
                                )
                              : _HitRow(
                                  hit: hits[i - commands.length],
                                  words: words,
                                  today: _state.today,
                                  onTap: () => _activate(i),
                                ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(-1),
      },
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: p.tile,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
        child: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            padding: dialogPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Search', style: dialogTitleStyle(p)),
                const SizedBox(height: dialogTitleGap),
                field,
                const SizedBox(height: dialogActionsGap),
                Row(
                  children: [
                    const Spacer(),
                    DialogDismiss(label: 'Close', onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(Palette p, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
      ),
    ),
  );
}

/// One result: what it is and its day over a line, then its words with
/// the matches lit.
class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.words, required this.today, required this.onTap});

  final SearchHit hit;
  final List<String> words;
  final DateTime today;
  final VoidCallback onTap;

  String get _when {
    final d = hit.day;
    if (hit.kind == 'ritual') {
      return '${monthNames[d.month - 1]}${d.year != today.year ? ' ${d.year}' : ''}';
    }
    final name = switch (daysBetween(today, d)) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    return [name ?? shortDay(d, today: d), if (d.year != today.year) '${d.year}'].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final caption = capsLabel(p.inkMuted);
    final body = TextStyle(fontFamily: Fonts.body, fontSize: 15, height: 1.4, color: hit.done ? p.inkMuted : p.ink);
    return FadeMenuRow(
      height: 56,
      grows: true,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(hit.kind == 'entry' ? 'RITUAL NOTE' : hit.kind.toUpperCase(), style: caption),
              Text('  ·  ', style: caption),
              Text(_when.toUpperCase(), style: caption),
              if (hit.done) ...[const SizedBox(width: 8), Icon(Icons.check_rounded, size: 14, color: briefBadgeInk(p))],
            ],
          ),
          const SizedBox(height: 4),
          Text.rich(_lit(hit.text, body, p), maxLines: hit.isJournal ? 2 : 1, overflow: TextOverflow.ellipsis),
          if (hit.subtask case final subtask?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: p.inkMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      _lit(subtask, body.copyWith(fontSize: 14), p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// [text] with [words] marked in the done colour.
  TextSpan _lit(String text, TextStyle style, Palette p) {
    final lit = style.copyWith(
      fontWeight: FontWeight.w600,
      color: p.ink,
      backgroundColor: p.done.withValues(alpha: 0.28),
    );
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in matchRanges(text, words)) {
      if (start < at || end > text.length) continue;
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      spans.add(TextSpan(text: text.substring(start, end), style: lit));
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}
