part of 'app_state.dart';

/// The app's state, with optional immutable selections to limit rebuilds.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.state, required super.child});
  final AppState state;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.state;

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.state;

  /// Call once per build with a record of the values/revisions that it draws.
  /// Commands should use [read] so they don't broaden the subscription.
  static AppState watch(BuildContext context, Object? Function(AppState) select) {
    final state = read(context);
    context.dependOnInheritedWidgetOfExactType<AppScope>(aspect: _StateSelection(select, select(state)));
    return state;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.state != state;

  @override
  InheritedElement createElement() => _AppScopeElement(this);
}

class _StateSelection {
  _StateSelection(this.select, this.value);
  final Object? Function(AppState) select;
  final Object? value;
}

class _AppScopeElement extends InheritedElement {
  _AppScopeElement(AppScope super.widget) {
    widget.state.addListener(_changed);
  }
  bool _dirty = false;

  @override
  AppScope get widget => super.widget as AppScope;

  void _changed() {
    _dirty = true;
    markNeedsBuild();
  }

  @override
  void update(AppScope newWidget) {
    if (widget.state != newWidget.state) {
      widget.state.removeListener(_changed);
      newWidget.state.addListener(_changed);
    }
    super.update(newWidget);
  }

  @override
  Widget build() {
    if (_dirty) notifyClients(widget);
    return super.build();
  }

  @override
  void updateDependencies(Element dependent, Object? aspect) => setDependencies(dependent, aspect);

  @override
  void notifyDependent(AppScope oldWidget, Element dependent) {
    final selection = getDependencies(dependent);
    if (oldWidget.state != widget.state ||
        selection is! _StateSelection ||
        selection.select(widget.state) != selection.value) {
      dependent.didChangeDependencies();
    }
  }

  @override
  void notifyClients(AppScope oldWidget) {
    super.notifyClients(oldWidget);
    _dirty = false;
  }

  @override
  void unmount() {
    widget.state.removeListener(_changed);
    super.unmount();
  }
}
