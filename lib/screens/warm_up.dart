import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_state.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/time_wheel.dart';
import 'month_view.dart';

/// Builds, once, out of sight and untouchable, the screens whose first
/// opening is otherwise a long frame (the app's code and fonts for them are
/// still cold): a month, Settings and the time wheel, one at a time, a
/// moment after the app starts and only while nothing is moving.
class WarmUp extends StatefulWidget {
  const WarmUp({super.key});

  /// Set by the app itself; tests build screens only when they ask to.
  static bool enabled = false;

  /// How long after the app shows it begins, and rests between screens.
  static const _begin = Duration(seconds: 1);
  static const _rest = Duration(milliseconds: 200);

  /// How long each stays: a month's grid builds over two frames.
  static const _frames = 3;

  @override
  State<WarmUp> createState() => _WarmUpState();
}

class _WarmUpState extends State<WarmUp> {
  late final List<WidgetBuilder> _screens = [
    (context) {
      final state = AppScope.read(context);
      return MonthView(year: state.today.year, month: state.today.month);
    },
    (_) => const SettingsDialog(),
    (_) => Center(
      child: SizedBox(
        width: 280,
        child: TimeWheel(initial: 9 * 60, onChanged: (_) {}),
      ),
    ),
  ];
  var _next = 0;
  WidgetBuilder? _building;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _wait = Timer(WarmUp._begin, _try);
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  /// Starts the next, unless something's moving: then a little later.
  void _try() {
    if (!mounted || _next >= _screens.length) return;
    if (AppScope.read(context).touring) return;
    if (SchedulerBinding.instance.transientCallbackCount > 0) {
      _wait = Timer(WarmUp._rest, _try);
      return;
    }
    setState(() => _building = _screens[_next++]);
    _hold(WarmUp._frames);
  }

  void _hold(int frames) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (frames > 1) {
        _hold(frames - 1);
        SchedulerBinding.instance.scheduleFrame();
      } else {
        setState(() => _building = null);
        _wait = Timer(WarmUp._rest, _try);
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final building = _building;
    if (building == null) return const SizedBox.shrink();
    return Offstage(
      child: TickerMode(
        enabled: false,
        child: ExcludeFocus(
          child: ExcludeSemantics(
            child: IgnorePointer(child: Builder(builder: building)),
          ),
        ),
      ),
    );
  }
}
