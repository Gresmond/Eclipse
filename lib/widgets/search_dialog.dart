import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/search.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_dialog.dart';
import 'confirm_on_enter.dart';
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
  final _focus = FocusNode();
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
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String query) {
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
    _state.showFound(hit.day, hit.target);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final hits = _hits, words = _words;
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
                  cursorColor: p.ink,
                  style: TextStyle(fontFamily: Fonts.body, fontSize: 15, color: p.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search tasks and journal',
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
                    decoration: BoxDecoration(
                      color: p.empty.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: words.isEmpty
                          ? _message(p, 'Find any task or journal entry, from any day.')
                          : hits.isEmpty
                          ? _message(p, curlyQuotes('Nothing matches "${_controller.text.trim()}".'))
                          : ScrollConfiguration(
                              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                itemCount:
                                    hits.length.clamp(0, SearchDialog.shown) +
                                    (hits.length > SearchDialog.shown ? 1 : 0),
                                separatorBuilder: (_, _) => const FadeMenuDivider(),
                                itemBuilder: (context, i) => i == SearchDialog.shown
                                    ? Padding(
                                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                                        child: Text(
                                          'Showing the newest ${SearchDialog.shown} of ${hits.length}. Add a word to narrow it.',
                                          style: TextStyle(fontFamily: Fonts.body, fontSize: 14, color: p.inkMuted),
                                        ),
                                      )
                                    : _HitRow(
                                        hit: hits[i],
                                        words: words,
                                        today: _state.today,
                                        onTap: () => _open(hits[i]),
                                      ),
                              ),
                            ),
                    ),
                  ),
                ),
      ],
    );
    return ConfirmOnEnter(
      // Opens the first result while searching, else closes.
      onConfirm: () => _controller.text.isEmpty ? Navigator.pop(context) : openFirst(),
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
