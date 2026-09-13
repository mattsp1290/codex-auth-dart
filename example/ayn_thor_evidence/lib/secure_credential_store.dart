import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Android secure-storage adapter with a journaled all-old-or-all-new record.
/// No method returns a stored credential outside a transaction.
final class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final _NamespaceMutex _mutex = _NamespaceMutex();
  static const _recordKey = 'codex_auth_record_v1';
  static const _pendingKey = 'codex_auth_pending_v1';
  final FlutterSecureStorage _storage;

  /// Resolves an interrupted write before any protected client operation.
  Future<void> recover() => _mutex.run(() async {
    final pending = await _storage.read(key: _pendingKey);
    if (pending != null) {
      await _storage.delete(key: _pendingKey);
      await _storage.delete(key: _recordKey);
    }
  });

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action,
  ) => _mutex.run(() async {
    final pending = await _storage.read(key: _pendingKey);
    if (pending != null) {
      await _storage.delete(key: _pendingKey);
      await _storage.delete(key: _recordKey);
    }
    return action(_SecureTransaction(_storage));
  });
}

final class _SecureTransaction implements CredentialTransaction {
  const _SecureTransaction(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<void> clear() async {
    await _storage.delete(key: SecureCredentialStore._pendingKey);
    await _storage.delete(key: SecureCredentialStore._recordKey);
  }

  @override
  Future<String?> read() =>
      _storage.read(key: SecureCredentialStore._recordKey);

  @override
  Future<void> replace(String record) async {
    await _storage.write(key: SecureCredentialStore._pendingKey, value: record);
    await _storage.write(key: SecureCredentialStore._recordKey, value: record);
    await _storage.delete(key: SecureCredentialStore._pendingKey);
  }
}

final class _NamespaceMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}
