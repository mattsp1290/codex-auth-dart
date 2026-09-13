import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

final class MemoryStore implements CredentialStore {
  String? value;
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action,
  ) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action(_MemoryTransaction(this));
    } finally {
      release.complete();
    }
  }
}

final class _MemoryTransaction implements CredentialTransaction {
  _MemoryTransaction(this.store);
  final MemoryStore store;
  @override
  Future<void> clear() async => store.value = null;
  @override
  Future<String?> read() async => store.value;
  @override
  Future<void> replace(String record) async => store.value = record;
}

void main() {
  test('transactions from independent users do not overlap', () async {
    final store = MemoryStore();
    final firstEntered = Completer<void>();
    final allowFirst = Completer<void>();
    var secondEntered = false;
    final first = store.transaction((_) async {
      firstEntered.complete();
      await allowFirst.future;
    });
    await firstEntered.future;
    final second = store.transaction((_) async => secondEntered = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondEntered, isFalse);
    allowFirst.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(secondEntered, isTrue);
  });
}
