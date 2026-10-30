import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/search.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'fade_menu.dart';

/// Settings' Search ribbon: every task and journal entry, any day, found as
/// you type. A result opens its day and lights it there.
class SettingsSearch extends StatefulWidget {
  const SettingsSearch({super.key});

  /// The results' box keeps one height, so the dialog doesn't jump as you type.
  static const height = 420.0;

  /// Results drawn at most; more words narrow it.
  static const shown = 100;

  @override
  State<SettingsSearch> createState() => SettingsSearchState();
}

class SettingsSearchState extends State<SettingsSearch> {
  late final _controller = TextEditingController(text: _state.lastSearch)
    ..selection = TextSelection(baseOffset: 0, extentOffset: _state.lastSearch.length);
  late final _state = AppScope.read(context);
  final _focus = FocusNode();
  late final SearchIndex _index;
  List<SearchHit> _hits = const [];
  List<String> _words = const [];

  @override
  void initState() {
    super.initState();
    _state.saveDrafts();
    _index = SearchIndex(_state.store);
    _search(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String query) {
    _state.lastSearch = query;
    setState(() {
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

  /// Opens the first result, for Enter.
  void openFirst() {
    if (_hits.isNotEmpty) _open(_hits.first);
  }

  void _open(SearchHit hit) {
    Navigator.pop(context);
    _state.showFound(hit.day, hit.uid ?? dateKey(hit.day));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(color: p.empty.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 18, color: p.inkMuted),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: _search,
                  cursorColor: p.ink,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search tasks and journal',
                    hintStyle: TextStyle(fontFamily: Fonts.body, color: p.inkMuted.withValues(alpha: 0.65)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_controller.text.isNotEmpty)
                TextFieldTapRegion(
                  child: IconButton(
                    tooltip: 'Clear',
                    onPressed: _clear,
                    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    padding: EdgeInsets.zero,
                    style: ButtonStyle(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
                      shape: const WidgetStatePropertyAll(CircleBorder()),
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) =>
                            states.contains(WidgetState.hovered) ? p.empty.withValues(alpha: 0.8) : Colors.transparent,
                      ),
                      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                    ),
                    icon: Icon(Icons.close_rounded, size: 16, color: p.inkMuted),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: SettingsSearch.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: p.empty.withValues(alpha: 0.45),
              child: _words.isEmpty
                  ? _message(p, 'Find any task or journal entry, from any day.')
                  : _hits.isEmpty
                  ? _message(p, curlyQuotes('Nothing matches "${_controller.text.trim()}".'))
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount:
                            _hits.length.clamp(0, SettingsSearch.shown) + (_hits.length > SettingsSearch.shown ? 1 : 0),
                        separatorBuilder: (_, _) => const FadeMenuDivider(),
                        itemBuilder: (context, i) => i == SettingsSearch.shown
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                                child: Text(
                                  'Showing the newest ${SettingsSearch.shown} of ${_hits.length}. Add a word to narrow it.',
                                  style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                                ),
                              )
                            : _HitRow(hit: _hits[i], words: _words, today: _state.today, onTap: () => _open(_hits[i])),
                      ),
                    ),
            ),
          ),
        ),
      ],
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
    final name = switch (daysBetween(today, d)) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => null,
    };
    final date = '${weekdayNames[d.weekday - 1].substring(0, 3)} ${d.day} ${monthNames[d.month - 1].substring(0, 3)}';
    return [name ?? date, if (d.year != today.year) '${d.year}'].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final caption = TextStyle(
      fontFamily: Fonts.ui,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: Scale.capsSpacing,
      color: p.inkMuted,
    );
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
              Text(hit.isJournal ? 'JOURNAL' : 'TASK', style: caption),
              Text('  ·  ', style: caption),
              Text(_when.toUpperCase(), style: caption),
              if (hit.done) ...[const SizedBox(width: 8), Icon(Icons.check_rounded, size: 14, color: p.done)],
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
