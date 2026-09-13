import 'dart:async';

/// A read-only cancellation signal.
abstract interface class CancellationSignal {
  /// Whether cancellation has already been requested.
  bool get isCancelled;

  /// Completes when cancellation is requested.
  Future<void> get whenCancelled;
}

/// Creates a signal which can be cancelled exactly once.
final class CancellationController implements CancellationSignal {
  final Completer<void> _completer = Completer<void>();

  @override
  bool get isCancelled => _completer.isCompleted;

  @override
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation. Repeated calls are harmless.
  void cancel() {
    if (!isCancelled) _completer.complete();
  }
}

/// A finite cancellation failure which deliberately contains no request data.
final class OperationCancelled implements Exception {
  @override
  String toString() => 'OperationCancelled';
}

/// Combines two signals without owning either signal.
final class CombinedCancellationSignal implements CancellationSignal {
  CombinedCancellationSignal(this._first, this._second);

  final CancellationSignal? _first;
  final CancellationSignal? _second;

  @override
  bool get isCancelled =>
      (_first?.isCancelled ?? false) || (_second?.isCancelled ?? false);

  @override
  Future<void> get whenCancelled => Future.any(<Future<void>>[
    if (_first != null) _first.whenCancelled,
    if (_second != null) _second.whenCancelled,
  ]);
}

void throwIfCancelled(CancellationSignal? signal) {
  if (signal?.isCancelled ?? false) throw OperationCancelled();
}
