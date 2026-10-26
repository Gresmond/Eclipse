import 'dart:collection';

/// A small, bounded cache. Reading an entry keeps it ahead of older entries.
class LruCache<K, V extends Object> extends MapBase<K, V> {
  LruCache(this.capacity, {this.onEvict}) : assert(capacity > 0);

  final int capacity;
  final void Function(V)? onEvict;
  final _values = <K, V>{};

  @override
  V? operator [](Object? key) {
    final value = _values.remove(key);
    if (value != null) _values[key as K] = value;
    return value;
  }

  @override
  void operator []=(K key, V value) {
    final old = _values.remove(key);
    if (old != null && !identical(old, value)) onEvict?.call(old);
    _values[key] = value;
    if (_values.length > capacity) remove(_values.keys.first);
  }

  @override
  Iterable<K> get keys => _values.keys.toList(growable: false);

  @override
  bool containsKey(Object? key) => _values.containsKey(key);

  @override
  V? remove(Object? key) {
    final value = _values.remove(key);
    if (value != null) onEvict?.call(value);
    return value;
  }

  @override
  void clear() {
    if (onEvict != null) {
      for (final value in _values.values) {
        onEvict!(value);
      }
    }
    _values.clear();
  }
}
