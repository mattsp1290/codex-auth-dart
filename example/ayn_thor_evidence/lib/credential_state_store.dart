import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:flutter/services.dart';

/// One encrypted, native-persisted credential envelope.
final class CredentialStateStore implements CredentialStore {
  CredentialStateStore({DurableRecordDriver? driver})
    : _driver = driver ?? const MethodChannelDurableRecordDriver();

  static final _NamespaceMutex _mutex = _NamespaceMutex();
  final DurableRecordDriver _driver;

  Future<AuthStatus> recover() => _mutex.run(_recoverUnlocked);

  Future<AuthStatus> _recoverUnlocked() async {
    _Envelope? envelope;
    try {
      envelope = await _readEnvelope();
    } on Object {
      await _clearFailClosed();
      return AuthStatus.reauthenticationRequired;
    }
    if (envelope == null || envelope.state == _EnvelopeState.signedOut) {
      return AuthStatus.signedOut;
    }
    if (envelope.state == _EnvelopeState.refreshRisk ||
        envelope.record == null) {
      await _clearFailClosed();
      return AuthStatus.reauthenticationRequired;
    }
    return AuthStatus.signedIn;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) => _mutex.run(() async {
    throwIfCancelled(cancellation);
    final recovered = await _recoverUnlocked();
    throwIfCancelled(cancellation);
    return action(_StateTransaction(this, recovered));
  }, cancellation: cancellation);

  Future<_Envelope?> _readEnvelope() async {
    final raw = await _driver.read();
    if (raw == null) return null;
    return _Envelope.decode(raw);
  }

  Future<void> _commit(_Envelope envelope) async {
    try {
      await _driver.commit(envelope.encode());
    } on Object {
      throw const CredentialStoreException();
    }
  }

  Future<void> _clearFailClosed() async {
    try {
      await _driver.clear();
    } on Object {
      throw const CredentialStoreException();
    }
  }
}

abstract interface class DurableRecordDriver {
  Future<String?> read();
  Future<void> commit(String envelope);
  Future<void> clear();
}

final class MethodChannelDurableRecordDriver implements DurableRecordDriver {
  const MethodChannelDurableRecordDriver();
  static const _channel = MethodChannel('codex_auth/durable_record_v1');

  @override
  Future<void> clear() async {
    if (await _channel.invokeMethod<bool>('clear') != true) {
      throw const CredentialStoreException();
    }
  }

  @override
  Future<void> commit(String envelope) async {
    if (await _channel.invokeMethod<bool>('commit', <String, Object?>{
          'value': envelope,
        }) !=
        true) {
      throw const CredentialStoreException();
    }
  }

  @override
  Future<String?> read() => _channel.invokeMethod<String>('read');
}

final class _StateTransaction implements CredentialTransaction {
  const _StateTransaction(this._store, this._recovery);
  final CredentialStateStore _store;
  final AuthStatus _recovery;
  @override
  bool get requiresReauthentication =>
      _recovery == AuthStatus.reauthenticationRequired;
  @override
  Future<void> clear() => _store._clearFailClosed();
  @override
  Future<void> clearAfterRefresh(String generation) async {
    final envelope = await _matchingRisk(generation);
    if (envelope == null) throw const CredentialStoreException();
    await _store._commit(_Envelope.signedOut);
  }

  @override
  Future<void> markRefreshRisk(String generation) async {
    final envelope = await _store._readEnvelope();
    if (envelope?.state != _EnvelopeState.idle || envelope?.record == null) {
      throw const CredentialStoreException();
    }
    await _store._commit(_Envelope.refreshRisk(generation, envelope!.record!));
  }

  @override
  Future<String?> read() async {
    if (requiresReauthentication) return null;
    final envelope = await _store._readEnvelope();
    return envelope?.state == _EnvelopeState.idle ? envelope?.record : null;
  }

  @override
  Future<void> replace(String record) => _store._commit(_Envelope.idle(record));
  @override
  Future<void> replaceAfterRefresh(String generation, String record) async {
    final envelope = await _matchingRisk(generation);
    if (envelope == null) throw const CredentialStoreException();
    await _store._commit(_Envelope.idle(record));
  }

  @override
  Future<void> restoreAfterNotDispatched(String generation) async {
    final envelope = await _matchingRisk(generation);
    if (envelope == null) throw const CredentialStoreException();
    await _store._commit(_Envelope.idle(envelope.record!));
  }

  Future<_Envelope?> _matchingRisk(String generation) async {
    final envelope = await _store._readEnvelope();
    return envelope?.state == _EnvelopeState.refreshRisk &&
            envelope?.generation == generation &&
            envelope?.record != null
        ? envelope
        : null;
  }
}

enum _EnvelopeState { idle, refreshRisk, signedOut }

final class _Envelope {
  const _Envelope._(this.state, this.record, this.generation);
  const _Envelope.idle(String record)
    : this._(_EnvelopeState.idle, record, null);
  const _Envelope.refreshRisk(String generation, String record)
    : this._(_EnvelopeState.refreshRisk, record, generation);
  static const signedOut = _Envelope._(_EnvelopeState.signedOut, null, null);
  final _EnvelopeState state;
  final String? record;
  final String? generation;
  String encode() => jsonEncode(<String, Object?>{
    'v': 1,
    'state': state.name,
    if (record != null) 'record': record,
    if (generation != null) 'generation': generation,
  });
  static _Envelope decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, Object?> || value['v'] != 1) {
      throw const FormatException();
    }
    return switch (value['state']) {
      'idle' when value['record'] is String => _Envelope.idle(
        value['record']! as String,
      ),
      'refreshRisk'
          when value['generation'] is String && value['record'] is String =>
        _Envelope.refreshRisk(
          value['generation']! as String,
          value['record']! as String,
        ),
      'signedOut' => signedOut,
      _ => throw const FormatException(),
    };
  }
}

final class _NamespaceMutex {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(
    Future<T> Function() action, {
    CancellationSignal? cancellation,
  }) async {
    final prior = _tail;
    final release = Completer<void>();
    _tail = release.future;
    var entered = false;
    try {
      throwIfCancelled(cancellation);
      if (cancellation == null) {
        await prior;
      } else {
        await Future.any(<Future<void>>[
          prior,
          cancellation.whenCancelled.then((_) => throw OperationCancelled()),
        ]);
      }
      throwIfCancelled(cancellation);
      entered = true;
      return await action();
    } finally {
      if (entered) {
        release.complete();
      } else {
        unawaited(prior.whenComplete(release.complete));
      }
    }
  }
}
