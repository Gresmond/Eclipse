import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/store.dart';
import '../models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/tile.dart';

enum InsightTone { win, slip }

/// One cross-app or behavioural observation shown in the Year view's Patterns card.
class YearInsight {
  const YearInsight({
    required this.lead,
    required this.detail,
    required this.tone,
    required this.strong,
    required this.score,
    required this.subject,
    required this.category,
  });

  final String lead;
  final String detail;
  final InsightTone tone;
  final bool strong;
  final double score;
  final String subject;
  final String category;
}

/// Smarter cross-app patterns across rituals, sleep schedule and tasks/week ahead,
/// placed below Sleep schedule in [YearView].
class YearInsightsCard extends StatefulWidget {
  const YearInsightsCard({super.key, required this.year, required this.rituals});

  final int year;

  /// Ritual ids scheduled on each shown, non-preview month of [year].
  final Map<int, Set<int>> rituals;

  /// How many times the insights engine recomputed for tests.
  @visibleForTesting
  static int debugComputes = 0;

  @override
  State<YearInsightsCard> createState() => _YearInsightsCardState();
}

class _YearInsightsCardState extends State<YearInsightsCard> {
  AppState? _state;
  int? _year, _habitsRev, _entriesRev, _todosRev;
  DateTime? _today;
  List<Holiday>? _holidays;
  Map<int, Set<int>>? _rituals;
  List<YearInsight>? _cached;

  static bool _sameHolidays(List<Holiday>? a, List<Holiday> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }

  static bool _sameRituals(Map<int, Set<int>>? a, Map<int, Set<int>> b) {
    if (a == null || a.length != b.length) return false;
    for (final entry in b.entries) {
      if (!setEquals(a[entry.key], entry.value)) return false;
    }
    return true;
  }

  List<YearInsight> _insightsFor(AppState state) {
    if (_cached != null &&
        identical(_state, state) &&
        _year == widget.year &&
        _habitsRev == state.habitsRevision &&
        _entriesRev == state.entriesRevision &&
        _todosRev == state.todosRevision &&
        _today == state.today &&
        _sameHolidays(_holidays, state.holidays) &&
        _sameRituals(_rituals, widget.rituals)) {
      return _cached!;
    }
    YearInsightsCard.debugComputes++;
    final computed = computeYearInsights(state, widget.year, widget.rituals);
    _state = state;
    _year = widget.year;
    _habitsRev = state.habitsRevision;
    _entriesRev = state.entriesRevision;
    _todosRev = state.todosRevision;
    _today = state.today;
    _holidays = List<Holiday>.of(state.holidays);
    _rituals = {for (final e in widget.rituals.entries) e.key: Set<int>.of(e.value)};
    return _cached = computed;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppScope.watch(
      context,
      (s) => (s.habitsRevision, s.entriesRevision, s.todosRevision, s.today, s.holidays),
    );
    final insights = _insightsFor(state);
    final header = capsLabel(p.inkMuted);
    final leadStyle = TextStyle(fontFamily: Fonts.body, fontSize: 14, fontWeight: FontWeight.w500, color: p.ink);
    final detailStyle = TextStyle(
      fontFamily: Fonts.body,
      fontSize: 14,
      color: p.inkMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final legendStyle = TextStyle(fontFamily: Fonts.ui, fontSize: 12, color: p.inkMuted);

    return Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('PATTERNS', style: header)),
              if (insights.isNotEmpty) ...[
                _LegendDot(color: p.done),
                const SizedBox(width: 6),
                Text('Works', style: legendStyle),
                const SizedBox(width: 14),
                _LegendDot(color: p.other),
                const SizedBox(width: 6),
                Text('Slips', style: legendStyle),
              ],
            ],
          ),
          const SizedBox(height: 16),
          if (insights.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'Patterns across rituals, sleep and tasks will appear here once there’s enough logged data.',
                style: leadStyle.copyWith(color: p.inkMuted, fontWeight: FontWeight.w400),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < insights.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: p.borderSoft),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: insights[i].tone == InsightTone.win
                                ? p.done
                                : (insights[i].strong ? p.missed : p.other),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: leadStyle,
                              children: [
                                TextSpan(text: insights[i].lead),
                                const TextSpan(text: '  '),
                                TextSpan(text: insights[i].detail, style: detailStyle),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _DayRecord {
  _DayRecord(this.key, this.day, {required this.rests, required this.onHoliday});

  final String key;
  final DateTime day;
  final bool rests;
  final bool onHoliday;

  int ritualsDone = 0;
  int ritualsLogged = 0;
  final Map<int, bool> ritualDone = {};
  final Map<SleepItem, bool> sleepDone = {};
  DayTaskStats? tasks;
}

const _minGroupDays = 5;
const _minWeekdayDays = 4;
const _minMomentumDays = 10;
const _eveningSleep = [SleepItem.sleepEarly, SleepItem.screenCurfew, SleepItem.unwind];
const _weekdaysPlural = ['Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays', 'Sundays'];

int _pct(num n, num d) => d == 0 ? 0 : (n * 100 / d).round();

double _score(int diffAbs, int minSamples, double boost) =>
    diffAbs * math.min(1.0, math.sqrt(minSamples / 12.0)) * boost;

/// Pure analysis pass across daily rituals, sleep schedule and tasks/week ahead
/// for [year], returning up to 8 balanced wins and slips ranked by strength.
List<YearInsight> computeYearInsights(AppState state, int year, Map<int, Set<int>> rituals) {
  final today = state.today;
  final holidays = state.holidays;
  final byKey = <String, _DayRecord>{};
  final names = <int, String>{};
  final isDailyRitual = <int, bool>{};
  final monthsLogged = <int>{};

  _DayRecord recordFor(DateTime day, String key) => byKey.putIfAbsent(
    key,
    () => _DayRecord(key, day, rests: restsOn(day, holidays: holidays), onHoliday: holidayOn(holidays, day) != null),
  );

  for (var month = 1; month <= 12; month++) {
    if (!state.isShownMonth(year, month) || state.isPreviewMonth(year, month)) continue;
    final ids = rituals[month] ?? const <int>{};
    final ritualById = <int, Habit>{};
    for (final h in state.habitsFor(year, month)) {
      names[h.id] = h.name;
      isDailyRitual[h.id] = h.weekly == null;
      if (ids.contains(h.id)) ritualById[h.id] = h;
    }
    final sleepList = state.sleepHabitsFor(year, month);
    final sleepById = <int, SleepItem>{
      for (var i = 0; i < sleepList.length && i < SleepItem.values.length; i++) sleepList[i].id: SleepItem.values[i],
    };

    for (final e in state.store.entriesInMonth(year, month)) {
      if (e.status == HabitStatus.none || e.status == HabitStatus.other) continue;
      final day = DateTime.tryParse(e.day);
      if (day == null || day.year != year || day.isAfter(today)) continue;
      final isDone = e.status == HabitStatus.done;

      if (sleepById[e.habitId] case final sleepItem?) {
        recordFor(day, e.day).sleepDone[sleepItem] = isDone;
        monthsLogged.add(month);
      } else if (ritualById[e.habitId] case final h?) {
        if (!h.startedBy(day) || !h.onDay(day)) continue;
        final rec = recordFor(day, e.day);
        rec.ritualsLogged++;
        if (isDone) rec.ritualsDone++;
        rec.ritualDone[h.id] = isDone;
        monthsLogged.add(month);
      }
    }
  }

  final taskStats = state.store.yearTaskStats(year, today);
  for (final MapEntry(key: key, value: s) in taskStats.entries) {
    final day = DateTime.tryParse(key);
    if (day == null || day.year != year || !day.isBefore(today)) continue;
    recordFor(day, key).tasks = s;
    if (s.planned > 0) monthsLogged.add(day.month);
  }

  if (byKey.isEmpty) return const [];

  final days = byKey.values.toList()..sort((a, b) => a.day.compareTo(b.day));
  final candidates = <YearInsight>[];

  // 1 & 2. Evening sleep (day d) -> next-day (d + 1) rituals, Rise Early, tasks.
  for (final item in _eveningSleep) {
    var ritDoneNum = 0, ritDoneDen = 0, ritDoneDays = 0;
    var ritMissNum = 0, ritMissDen = 0, ritMissDays = 0;
    var riseDone = 0, riseDoneDays = 0, riseMiss = 0, riseMissDays = 0;
    var taskDoneOnGood = 0, taskPlanOnGood = 0, taskGoodDays = 0;
    var taskDoneOnMiss = 0, taskPlanOnMiss = 0, taskMissDays = 0;

    final perRitualDoneYes = <int, int>{};
    final perRitualDaysYes = <int, int>{};
    final perRitualDoneNo = <int, int>{};
    final perRitualDaysNo = <int, int>{};

    for (final rec in days) {
      if (rec.rests) continue;
      final slept = rec.sleepDone[item];
      if (slept == null) continue;
      final nextDay = DateTime(rec.day.year, rec.day.month, rec.day.day + 1);
      if (nextDay.year != year) continue;
      final next = byKey[dateKey(nextDay)];
      if (next == null) continue;

      if (!next.rests && next.ritualsLogged > 0) {
        if (slept) {
          ritDoneNum += next.ritualsDone;
          ritDoneDen += next.ritualsLogged;
          ritDoneDays++;
        } else {
          ritMissNum += next.ritualsDone;
          ritMissDen += next.ritualsLogged;
          ritMissDays++;
        }
        for (final MapEntry(key: rid, value: rDone) in next.ritualDone.entries) {
          if (slept) {
            perRitualDaysYes[rid] = (perRitualDaysYes[rid] ?? 0) + 1;
            if (rDone) perRitualDoneYes[rid] = (perRitualDoneYes[rid] ?? 0) + 1;
          } else {
            perRitualDaysNo[rid] = (perRitualDaysNo[rid] ?? 0) + 1;
            if (rDone) perRitualDoneNo[rid] = (perRitualDoneNo[rid] ?? 0) + 1;
          }
        }
      }

      if (!next.rests) {
        if (next.sleepDone[SleepItem.riseEarly] case final roseEarly?) {
          if (slept) {
            riseDoneDays++;
            if (roseEarly) riseDone++;
          } else {
            riseMissDays++;
            if (roseEarly) riseMiss++;
          }
        }
      }

      if (!next.onHoliday && next.tasks != null && next.tasks!.planned > 0) {
        final t = next.tasks!;
        if (slept) {
          taskGoodDays++;
          taskDoneOnGood += t.done;
          taskPlanOnGood += t.planned;
        } else {
          taskMissDays++;
          taskDoneOnMiss += t.done;
          taskPlanOnMiss += t.planned;
        }
      }
    }

    var overallRitDiff = 0;
    if (ritDoneDays >= _minGroupDays && ritMissDays >= _minGroupDays) {
      final donePct = _pct(ritDoneNum, ritDoneDen);
      final missPct = _pct(ritMissNum, ritMissDen);
      overallRitDiff = donePct - missPct;
      if (overallRitDiff >= 12) {
        candidates.add(
          YearInsight(
            lead: '${item.label} lifts next-day rituals',
            detail: '$donePct% after, vs $missPct% when missed',
            tone: InsightTone.win,
            strong: true,
            score: _score(overallRitDiff, math.min(ritDoneDays, ritMissDays), 1.35),
            subject: 'sleep:${item.name}',
            category: 'sleep->rituals',
          ),
        );
      }
    }

    // Check individual ritual most responsive to this sleep habit.
    YearInsight? bestSpecific;
    for (final rid in perRitualDaysYes.keys) {
      final dYes = perRitualDaysYes[rid] ?? 0;
      final dNo = perRitualDaysNo[rid] ?? 0;
      if (dYes < _minGroupDays || dNo < _minGroupDays) continue;
      final pYes = _pct(perRitualDoneYes[rid] ?? 0, dYes);
      final pNo = _pct(perRitualDoneNo[rid] ?? 0, dNo);
      final diff = pYes - pNo;
      if (diff >= 20 && diff >= overallRitDiff + 8) {
        final s = _score(diff, math.min(dYes, dNo), 1.3);
        if (bestSpecific == null || s > bestSpecific.score) {
          bestSpecific = YearInsight(
            lead: '${item.label} helps ${names[rid]} the next day',
            detail: '$pYes% after, vs $pNo% when missed',
            tone: InsightTone.win,
            strong: true,
            score: s,
            subject: 'ritual:$rid',
            category: 'sleep->ritual',
          );
        }
      }
    }
    if (bestSpecific != null) candidates.add(bestSpecific);

    if (riseDoneDays >= _minGroupDays && riseMissDays >= _minGroupDays) {
      final donePct = _pct(riseDone, riseDoneDays);
      final missPct = _pct(riseMiss, riseMissDays);
      final diff = donePct - missPct;
      if (diff >= 18) {
        candidates.add(
          YearInsight(
            lead: '${item.label} sets up Rise Early',
            detail: '$donePct% next morning, vs $missPct% when missed',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(riseDoneDays, riseMissDays), 1.25),
            subject: 'sleep:${item.name}',
            category: 'sleep->rise',
          ),
        );
      }
    }

    if (taskGoodDays >= _minGroupDays && taskMissDays >= _minGroupDays) {
      final donePct = _pct(taskDoneOnGood, taskPlanOnGood);
      final missPct = _pct(taskDoneOnMiss, taskPlanOnMiss);
      final diff = donePct - missPct;
      if (diff >= 12) {
        candidates.add(
          YearInsight(
            lead: '${item.label} boosts next-day tasks',
            detail: '$donePct% finished next day, vs $missPct% when missed',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(taskGoodDays, taskMissDays), 1.35),
            subject: 'sleep:${item.name}',
            category: 'sleep->tasks',
          ),
        );
      }
    }
  }

  // 3. Same-day Rise Early -> today's rituals & today's tasks.
  {
    var ritDoneE = 0, ritDenE = 0, ritDaysE = 0, ritDoneL = 0, ritDenL = 0, ritDaysL = 0;
    var tDoneE = 0, tPlanE = 0, tDaysE = 0, tDoneL = 0, tPlanL = 0, tDaysL = 0;
    for (final rec in days) {
      if (rec.rests) continue;
      final rose = rec.sleepDone[SleepItem.riseEarly];
      if (rose == null) continue;
      if (rec.ritualsLogged > 0) {
        if (rose) {
          ritDoneE += rec.ritualsDone;
          ritDenE += rec.ritualsLogged;
          ritDaysE++;
        } else {
          ritDoneL += rec.ritualsDone;
          ritDenL += rec.ritualsLogged;
          ritDaysL++;
        }
      }
      if (rec.tasks != null && rec.tasks!.planned > 0) {
        final t = rec.tasks!;
        if (rose) {
          tDoneE += t.done;
          tPlanE += t.planned;
          tDaysE++;
        } else {
          tDoneL += t.done;
          tPlanL += t.planned;
          tDaysL++;
        }
      }
    }
    if (ritDaysE >= _minGroupDays && ritDaysL >= _minGroupDays) {
      final ePct = _pct(ritDoneE, ritDenE), lPct = _pct(ritDoneL, ritDenL);
      final diff = ePct - lPct;
      if (diff >= 12) {
        candidates.add(
          YearInsight(
            lead: 'Rise Early sets up the day’s rituals',
            detail: '$ePct% done, vs $lPct% on late mornings',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(ritDaysE, ritDaysL), 1.35),
            subject: 'sleep:riseEarly',
            category: 'rise->rituals',
          ),
        );
      }
    }
    if (tDaysE >= _minGroupDays && tDaysL >= _minGroupDays) {
      final ePct = _pct(tDoneE, tPlanE), lPct = _pct(tDoneL, tPlanL);
      final diff = ePct - lPct;
      if (diff >= 12) {
        candidates.add(
          YearInsight(
            lead: 'Tasks finish stronger after Rise Early',
            detail: '$ePct% finished, vs $lPct% on late mornings',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(tDaysE, tDaysL), 1.35),
            subject: 'sleep:riseEarly',
            category: 'rise->tasks',
          ),
        );
      }
    }
  }

  // 4. Tasks / Week ahead <-> Rituals & Sleep.
  // 4a. Clearing all tasks vs leaving unfinished tasks.
  {
    var rDoneC = 0, rDenC = 0, rDaysC = 0, rDoneO = 0, rDenO = 0, rDaysO = 0;
    var sDoneC = 0, sDenC = 0, sDaysC = 0, sDoneO = 0, sDenO = 0, sDaysO = 0;
    for (final rec in days) {
      if (rec.rests || rec.tasks == null || rec.tasks!.planned == 0) continue;
      final cleared = rec.tasks!.unfinished == 0;
      if (rec.ritualsLogged > 0) {
        if (cleared) {
          rDoneC += rec.ritualsDone;
          rDenC += rec.ritualsLogged;
          rDaysC++;
        } else {
          rDoneO += rec.ritualsDone;
          rDenO += rec.ritualsLogged;
          rDaysO++;
        }
      }
      var eveningLogged = 0, eveningDone = 0;
      for (final item in _eveningSleep) {
        if (rec.sleepDone[item] case final v?) {
          eveningLogged++;
          if (v) eveningDone++;
        }
      }
      if (eveningLogged > 0) {
        if (cleared) {
          sDoneC += eveningDone;
          sDenC += eveningLogged;
          sDaysC++;
        } else {
          sDoneO += eveningDone;
          sDenO += eveningLogged;
          sDaysO++;
        }
      }
    }
    if (rDaysC >= _minGroupDays && rDaysO >= _minGroupDays) {
      final cPct = _pct(rDoneC, rDenC), oPct = _pct(rDoneO, rDenO);
      final diff = cPct - oPct;
      if (diff >= 12) {
        candidates.add(
          YearInsight(
            lead: 'Clearing your tasks goes with strong rituals',
            detail: '$cPct% of rituals done, vs $oPct% when tasks roll over',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(rDaysC, rDaysO), 1.35),
            subject: 'tasks:clear',
            category: 'tasks->rituals',
          ),
        );
      }
    }
    if (sDaysC >= _minGroupDays && sDaysO >= _minGroupDays) {
      final cPct = _pct(sDoneC, sDenC), oPct = _pct(sDoneO, sDenO);
      final diff = cPct - oPct;
      if (diff >= 12) {
        candidates.add(
          YearInsight(
            lead: 'Unfinished tasks weigh on evening sleep',
            detail: '$oPct% sleep habits done, vs $cPct% when tasks are cleared',
            tone: InsightTone.slip,
            strong: diff >= 25,
            score: _score(diff, math.min(sDaysC, sDaysO), 1.35),
            subject: 'tasks:clear',
            category: 'tasks->sleep',
          ),
        );
      }
    }
  }

  // 4b. Heavy task days vs lighter days.
  {
    final taskDayCounts = [
      for (final rec in days)
        if (!rec.onHoliday && rec.tasks != null && rec.tasks!.planned > 0) rec.tasks!.planned,
    ]..sort();
    if (taskDayCounts.length >= 2 * _minGroupDays) {
      final median = taskDayCounts[taskDayCounts.length ~/ 2];
      final heavyThreshold = math.max(4, median + 2);
      var rDoneH = 0, rDenH = 0, rDaysH = 0, rDoneL = 0, rDenL = 0, rDaysL = 0;
      var tDoneH = 0, tPlanH = 0, tDaysH = 0, tDoneL = 0, tPlanL = 0, tDaysL = 0;
      for (final rec in days) {
        if (rec.onHoliday || rec.tasks == null || rec.tasks!.planned == 0) continue;
        final t = rec.tasks!;
        final heavy = t.planned >= heavyThreshold;
        if (heavy) {
          tDoneH += t.done;
          tPlanH += t.planned;
          tDaysH++;
        } else {
          tDoneL += t.done;
          tPlanL += t.planned;
          tDaysL++;
        }
        if (!rec.rests && rec.ritualsLogged > 0) {
          if (heavy) {
            rDoneH += rec.ritualsDone;
            rDenH += rec.ritualsLogged;
            rDaysH++;
          } else {
            rDoneL += rec.ritualsDone;
            rDenL += rec.ritualsLogged;
            rDaysL++;
          }
        }
      }
      if (rDaysH >= _minGroupDays && rDaysL >= _minGroupDays) {
        final hPct = _pct(rDoneH, rDenH), lPct = _pct(rDoneL, rDenL);
        final drop = lPct - hPct;
        if (drop >= 12) {
          candidates.add(
            YearInsight(
              lead: 'Heavy task days squeeze daily rituals',
              detail: '$hPct% done with $heavyThreshold+ tasks, vs $lPct% on lighter days',
              tone: InsightTone.slip,
              strong: drop >= 25,
              score: _score(drop, math.min(rDaysH, rDaysL), 1.35),
              subject: 'tasks:load',
              category: 'heavy->rituals',
            ),
          );
        }
      }
      if (tDaysH >= _minGroupDays && tDaysL >= _minGroupDays) {
        final hPct = _pct(tDoneH, tPlanH), lPct = _pct(tDoneL, tPlanL);
        final drop = lPct - hPct;
        if (drop >= 15) {
          candidates.add(
            YearInsight(
              lead: 'Overpacked days leave more tasks undone',
              detail: '$hPct% finished with $heavyThreshold+ tasks, vs $lPct% on lighter days',
              tone: InsightTone.slip,
              strong: drop >= 25,
              score: _score(drop, math.min(tDaysH, tDaysL), 1.15),
              subject: 'tasks:load',
              category: 'heavy->tasks',
            ),
          );
        }
      }
    }
  }

  // 4c. Carried-over vs fresh tasks.
  {
    var freshPlan = 0, freshDone = 0, carriedPlan = 0, carriedDone = 0;
    for (final rec in days) {
      if (rec.onHoliday || rec.tasks == null) continue;
      final t = rec.tasks!;
      freshPlan += t.freshPlanned;
      freshDone += t.freshDone;
      carriedPlan += t.carriedPlanned;
      carriedDone += t.carriedDone;
    }
    if (freshPlan >= 10 && carriedPlan >= 10) {
      final fPct = _pct(freshDone, freshPlan);
      final cPct = _pct(carriedDone, carriedPlan);
      final drop = fPct - cPct;
      if (drop >= 15) {
        candidates.add(
          YearInsight(
            lead: 'Carried-over tasks stall once they roll over',
            detail: '$cPct% finished once carried, vs $fPct% on their first day',
            tone: InsightTone.slip,
            strong: drop >= 30,
            score: _score(drop, math.min(freshPlan, carriedPlan) ~/ 2, 1.15),
            subject: 'tasks:carried',
            category: 'tasks:carried',
          ),
        );
      }
    }
  }

  // 4d & 5. Keystone daily rituals -> same-day tasks & other rituals.
  for (final MapEntry(key: rid, value: isDaily) in isDailyRitual.entries) {
    if (!isDaily) continue;
    final rName = names[rid] ?? '';
    var tDoneY = 0, tPlanY = 0, tDaysY = 0, tDoneN = 0, tPlanN = 0, tDaysN = 0;
    var oDoneY = 0, oDenY = 0, oDaysY = 0, oDoneN = 0, oDenN = 0, oDaysN = 0;
    for (final rec in days) {
      if (rec.rests) continue;
      final rDone = rec.ritualDone[rid];
      if (rDone == null) continue;
      if (rec.tasks != null && rec.tasks!.planned > 0) {
        final t = rec.tasks!;
        if (rDone) {
          tDoneY += t.done;
          tPlanY += t.planned;
          tDaysY++;
        } else {
          tDoneN += t.done;
          tPlanN += t.planned;
          tDaysN++;
        }
      }
      if (rec.ritualsLogged > 1) {
        final otherDone = rec.ritualsDone - (rDone ? 1 : 0);
        final otherLogged = rec.ritualsLogged - 1;
        if (rDone) {
          oDoneY += otherDone;
          oDenY += otherLogged;
          oDaysY++;
        } else {
          oDoneN += otherDone;
          oDenN += otherLogged;
          oDaysN++;
        }
      }
    }
    if (tDaysY >= _minGroupDays && tDaysN >= _minGroupDays) {
      final yPct = _pct(tDoneY, tPlanY), nPct = _pct(tDoneN, tPlanN);
      final diff = yPct - nPct;
      if (diff >= 15) {
        candidates.add(
          YearInsight(
            lead: 'Days with $rName see more tasks finished',
            detail: '$yPct% of tasks done, vs $nPct% without it',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(tDaysY, tDaysN), 1.35),
            subject: 'ritual:$rid',
            category: 'ritual->tasks',
          ),
        );
      }
    }
    if (oDaysY >= _minGroupDays && oDaysN >= _minGroupDays) {
      final yPct = _pct(oDoneY, oDenY), nPct = _pct(oDoneN, oDenN);
      final diff = yPct - nPct;
      if (diff >= 15) {
        candidates.add(
          YearInsight(
            lead: '$rName anchors the rest of your rituals',
            detail: '$yPct% of other rituals done, vs $nPct% when missed',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(oDaysY, oDaysN), 1.15),
            subject: 'ritual:$rid',
            category: 'ritual->rituals',
          ),
        );
      }
    }
  }

  // 6a. Weekday slips & wins for daily rituals (Mon-Fri only, excluding rest weekends & holidays).
  {
    final loggedOn = <int, List<int>>{};
    final doneOn = <int, List<int>>{};
    for (final rec in days) {
      if (rec.rests || rec.day.weekday >= DateTime.saturday) continue;
      final wd = rec.day.weekday - 1;
      for (final MapEntry(key: rid, value: rDone) in rec.ritualDone.entries) {
        if (isDailyRitual[rid] != true) continue;
        (loggedOn[rid] ??= List.filled(5, 0))[wd]++;
        (doneOn[rid] ??= List.filled(5, 0))[wd] += rDone ? 1 : 0;
      }
    }
    for (final MapEntry(key: rid, value: wdDays) in loggedOn.entries) {
      final wdTicks = doneOn[rid]!;
      final totalDays = wdDays.fold(0, (a, b) => a + b);
      final totalTicks = wdTicks.fold(0, (a, b) => a + b);
      if (totalDays == 0) continue;
      final usual = totalTicks * 100 / totalDays;
      final rName = names[rid] ?? '';
      int? worstWd, bestWd;
      double? worstRate, bestRate;
      for (var i = 0; i < 5; i++) {
        if (wdDays[i] < _minWeekdayDays) continue;
        final rate = wdTicks[i] * 100 / wdDays[i];
        if (worstRate == null || rate < worstRate) (worstWd, worstRate) = (i, rate);
        if (bestRate == null || rate > bestRate) (bestWd, bestRate) = (i, rate);
      }
      if (worstWd != null && usual - worstRate! >= 15) {
        final ratePct = worstRate.round(), usualPct = usual.round();
        final drop = usualPct - ratePct;
        candidates.add(
          YearInsight(
            lead: '$rName slips on ${_weekdaysPlural[worstWd]}',
            detail: '$ratePct%, usually $usualPct%',
            tone: InsightTone.slip,
            strong: drop >= 30,
            score: _score(drop, wdDays[worstWd], 1.0),
            subject: 'ritual:$rid',
            category: 'weekday-ritual-slip',
          ),
        );
      }
      if (bestWd != null) {
        final ratePct = bestRate!.round(), usualPct = usual.round();
        final lift = ratePct - usualPct;
        if ((lift >= 15 && ratePct >= 80) || (ratePct == 100 && usualPct <= 85 && wdDays[bestWd] >= 5)) {
          candidates.add(
            YearInsight(
              lead: '$rName shines on ${_weekdaysPlural[bestWd]}',
              detail: '$ratePct%, usually $usualPct%',
              tone: InsightTone.win,
              strong: true,
              score: _score(lift, wdDays[bestWd], 1.0),
              subject: 'ritual:$rid',
              category: 'weekday-ritual-win',
            ),
          );
        }
      }
    }
  }

  // 6b. Weekday dips & wins for sleep schedule (Mon-Fri, excluding holidays).
  for (final item in SleepItem.values) {
    final wdDays = List.filled(5, 0);
    final wdTicks = List.filled(5, 0);
    for (final rec in days) {
      if (rec.rests || rec.day.weekday >= DateTime.saturday) continue;
      if (rec.sleepDone[item] case final sDone?) {
        final wd = rec.day.weekday - 1;
        wdDays[wd]++;
        if (sDone) wdTicks[wd]++;
      }
    }
    final totalDays = wdDays.fold(0, (a, b) => a + b);
    final totalTicks = wdTicks.fold(0, (a, b) => a + b);
    if (totalDays == 0) continue;
    final usual = totalTicks * 100 / totalDays;
    int? worstWd, bestWd;
    double? worstRate, bestRate;
    for (var i = 0; i < 5; i++) {
      if (wdDays[i] < _minWeekdayDays) continue;
      final rate = wdTicks[i] * 100 / wdDays[i];
      if (worstRate == null || rate < worstRate) (worstWd, worstRate) = (i, rate);
      if (bestRate == null || rate > bestRate) (bestWd, bestRate) = (i, rate);
    }
    if (worstWd != null && usual - worstRate! >= 15) {
      final ratePct = worstRate.round(), usualPct = usual.round();
      final drop = usualPct - ratePct;
      candidates.add(
        YearInsight(
          lead: '${item.label} dips on ${_weekdaysPlural[worstWd]}',
          detail: '$ratePct%, usually $usualPct%',
          tone: InsightTone.slip,
          strong: drop >= 30,
          score: _score(drop, wdDays[worstWd], 1.0),
          subject: 'sleep:${item.name}',
          category: 'weekday-sleep-slip',
        ),
      );
    }
    if (bestWd != null && bestRate! - usual >= 15 && bestRate >= 80) {
      final ratePct = bestRate.round(), usualPct = usual.round();
      final lift = ratePct - usualPct;
      candidates.add(
        YearInsight(
          lead: '${item.label} holds strongest on ${_weekdaysPlural[bestWd]}',
          detail: '$ratePct%, usually $usualPct%',
          tone: InsightTone.win,
          strong: true,
          score: _score(lift, wdDays[bestWd], 1.0),
          subject: 'sleep:${item.name}',
          category: 'weekday-sleep-win',
        ),
      );
    }
  }

  // 6c. Weekday task completion patterns (Mon-Sun, excluding holidays).
  {
    final wdDayCount = List.filled(7, 0);
    final wdPlan = List.filled(7, 0);
    final wdDone = List.filled(7, 0);
    for (final rec in days) {
      if (rec.onHoliday || rec.tasks == null || rec.tasks!.planned == 0) continue;
      final wd = rec.day.weekday - 1;
      wdDayCount[wd]++;
      wdPlan[wd] += rec.tasks!.planned;
      wdDone[wd] += rec.tasks!.done;
    }
    final totalPlan = wdPlan.fold(0, (a, b) => a + b);
    final totalDone = wdDone.fold(0, (a, b) => a + b);
    if (totalPlan > 0) {
      final usual = totalDone * 100 / totalPlan;
      int? worstWd, bestWd;
      double? worstRate, bestRate;
      for (var i = 0; i < 7; i++) {
        if (wdDayCount[i] < _minWeekdayDays || wdPlan[i] == 0) continue;
        final rate = wdDone[i] * 100 / wdPlan[i];
        if (worstRate == null || rate < worstRate) (worstWd, worstRate) = (i, rate);
        if (bestRate == null || rate > bestRate) (bestWd, bestRate) = (i, rate);
      }
      if (worstWd != null && usual - worstRate! >= 15) {
        final ratePct = worstRate.round(), usualPct = usual.round();
        candidates.add(
          YearInsight(
            lead: 'Tasks slip on ${_weekdaysPlural[worstWd]}',
            detail: '$ratePct% finished, usually $usualPct%',
            tone: InsightTone.slip,
            strong: (usualPct - ratePct) >= 30,
            score: _score(usualPct - ratePct, wdDayCount[worstWd], 1.0),
            subject: 'tasks:weekday',
            category: 'weekday-task-slip',
          ),
        );
      }
      if (bestWd != null && bestRate! - usual >= 15 && bestRate >= 70) {
        final ratePct = bestRate.round(), usualPct = usual.round();
        candidates.add(
          YearInsight(
            lead: '${_weekdaysPlural[bestWd]} are your strongest task day',
            detail: '$ratePct% finished, usually $usualPct%',
            tone: InsightTone.win,
            strong: true,
            score: _score(ratePct - usualPct, wdDayCount[bestWd], 1.0),
            subject: 'tasks:weekday',
            category: 'weekday-task-win',
          ),
        );
      }
    }
  }

  // 7. Recent 30-day momentum (wins & dips) once >= 2 months of year data exist.
  if (year == today.year && monthsLogged.length >= 2) {
    final cutoff = DateTime(today.year, today.month, today.day - 29);
    var rDoneRec = 0, rDenRec = 0, rDaysRec = 0, rDoneOld = 0, rDenOld = 0, rDaysOld = 0;
    var sDoneRec = 0, sDenRec = 0, sDaysRec = 0, sDoneOld = 0, sDenOld = 0, sDaysOld = 0;
    var tDoneRec = 0, tPlanRec = 0, tDaysRec = 0, tDoneOld = 0, tPlanOld = 0, tDaysOld = 0;
    final perRitRec = <int, (int done, int days)>{};
    final perRitOld = <int, (int done, int days)>{};

    for (final rec in days) {
      final isRecent = !rec.day.isBefore(cutoff);
      if (!rec.rests) {
        if (rec.ritualsLogged > 0) {
          if (isRecent) {
            rDoneRec += rec.ritualsDone;
            rDenRec += rec.ritualsLogged;
            rDaysRec++;
          } else {
            rDoneOld += rec.ritualsDone;
            rDenOld += rec.ritualsLogged;
            rDaysOld++;
          }
        }
        for (final MapEntry(key: rid, value: done) in rec.ritualDone.entries) {
          if (isDailyRitual[rid] != true) continue;
          final map = isRecent ? perRitRec : perRitOld;
          final prev = map[rid] ?? (0, 0);
          map[rid] = (prev.$1 + (done ? 1 : 0), prev.$2 + 1);
        }
        if (rec.sleepDone.isNotEmpty) {
          final sDone = rec.sleepDone.values.where((v) => v).length;
          final sDen = rec.sleepDone.length;
          if (isRecent) {
            sDoneRec += sDone;
            sDenRec += sDen;
            sDaysRec++;
          } else {
            sDoneOld += sDone;
            sDenOld += sDen;
            sDaysOld++;
          }
        }
      }
      if (!rec.onHoliday && rec.tasks != null && rec.tasks!.planned > 0) {
        final t = rec.tasks!;
        if (isRecent) {
          tDoneRec += t.done;
          tPlanRec += t.planned;
          tDaysRec++;
        } else {
          tDoneOld += t.done;
          tPlanOld += t.planned;
          tDaysOld++;
        }
      }
    }

    void addMomentum(String label, String subject, int recDone, int recDen, int recDays, int oldDone, int oldDen, int oldDays, int minDiff) {
      if (recDays < _minMomentumDays || oldDays < _minMomentumDays) return;
      final recPct = _pct(recDone, recDen);
      final oldPct = _pct(oldDone, oldDen);
      final diff = recPct - oldPct;
      if (diff >= minDiff) {
        candidates.add(
          YearInsight(
            lead: '$label is climbing lately',
            detail: '$recPct% over the last 30 days, up from $oldPct%',
            tone: InsightTone.win,
            strong: true,
            score: _score(diff, math.min(recDays, oldDays), 1.15),
            subject: subject,
            category: 'momentum',
          ),
        );
      } else if (-diff >= minDiff) {
        candidates.add(
          YearInsight(
            lead: '$label has dipped lately',
            detail: '$recPct% over the last 30 days, down from $oldPct%',
            tone: InsightTone.slip,
            strong: (-diff) >= 25,
            score: _score(-diff, math.min(recDays, oldDays), 1.15),
            subject: subject,
            category: 'momentum',
          ),
        );
      }
    }

    addMomentum('Daily rituals', 'rituals:all', rDoneRec, rDenRec, rDaysRec, rDoneOld, rDenOld, rDaysOld, 15);
    addMomentum('Sleep schedule', 'sleep:all', sDoneRec, sDenRec, sDaysRec, sDoneOld, sDenOld, sDaysOld, 15);
    addMomentum('Task completion', 'tasks:all', tDoneRec, tPlanRec, tDaysRec, tDoneOld, tPlanOld, tDaysOld, 15);
    for (final rid in perRitRec.keys) {
      final (rd, rl) = perRitRec[rid]!;
      final (od, ol) = perRitOld[rid] ?? (0, 0);
      addMomentum(names[rid] ?? '', 'ritual:$rid', rd, rl, rl, od, ol, ol, 20);
    }
  }

  candidates.sort((a, b) {
    final s = b.score.compareTo(a.score);
    return s != 0 ? s : a.lead.compareTo(b.lead);
  });

  // Deduplicate by (category, subject) and cap at 2 insights per subject.
  final seenPair = <(String, String)>{};
  final perSubject = <String, int>{};
  final deduped = <YearInsight>[];
  for (final item in candidates) {
    if (!seenPair.add((item.category, item.subject))) continue;
    final count = perSubject[item.subject] ?? 0;
    if (count >= 2) continue;
    perSubject[item.subject] = count + 1;
    deduped.add(item);
  }

  // Combined ranked list (max 8); when both wins and slips exist, cap either
  // polarity at 5 so both sides show cleanly.
  final hasWins = deduped.any((i) => i.tone == InsightTone.win);
  final hasSlips = deduped.any((i) => i.tone == InsightTone.slip);
  final cap = hasWins && hasSlips ? 5 : 8;
  final result = <YearInsight>[];
  var wins = 0, slips = 0;
  for (final item in deduped) {
    if (item.tone == InsightTone.win) {
      if (wins >= cap) continue;
      wins++;
    } else {
      if (slips >= cap) continue;
      slips++;
    }
    result.add(item);
    if (result.length >= 8) break;
  }
  return result;
}
