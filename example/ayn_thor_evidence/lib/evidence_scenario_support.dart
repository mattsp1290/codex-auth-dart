import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';

import 'credential_state_store.dart';
import 'evidence_controls.dart';
import 'evidence_state_store.dart';

/// Evidence-only finite request counters and one-shot refresh substitution.
/// Request values are never retained or rendered.
final class EvidenceTransport implements HttpTransport {
  EvidenceTransport(this._inner, {this.substituteInvalidGrant = false});

  final HttpTransport _inner;
  final bool substituteInvalidGrant;
  int refreshCount = 0;
  int protectedIo = 0;
  bool substitutionApplied = false;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) {
    var outbound = request;
    if (_isRefresh(request)) {
      refreshCount++;
      if (substituteInvalidGrant && !substitutionApplied) {
        final fields = Uri.splitQueryString(utf8.decode(request.body));
        outbound = HttpRequestData(
          method: request.method,
          uri: request.uri,
          headers: request.headers,
          body: _formBody(<String, String>{
            for (final entry in fields.entries)
              if (entry.key != 'refresh_token') entry.key: entry.value,
            'refresh_token': 'evidence-invalid-refresh-value',
          }),
        );
        substitutionApplied = true;
      }
    }
    if (_isProtected(request)) protectedIo++;
    return _inner.send(outbound, cancellation: cancellation);
  }

  bool _isRefresh(HttpRequestData request) =>
      request.uri.path == '/oauth/token' &&
      utf8.decode(request.body).contains('grant_type=refresh_token');

  bool _isProtected(HttpRequestData request) =>
      request.uri.path == '/backend-api/codex/models' ||
      request.uri.path == '/backend-api/codex/responses';
}

List<int> _formBody(Map<String, String> values) => utf8.encode(
  values.entries
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&'),
);

/// Tracks whether supposedly exclusive credential transactions overlap.
final class EvidenceTransactionTracker {
  var _active = 0;
  bool overlapObserved = false;

  Future<T> run<T>(Future<T> Function() action) async {
    _active++;
    if (_active > 1) overlapObserved = true;
    try {
      return await action();
    } finally {
      _active--;
    }
  }
}

final class TrackedCredentialStore implements CredentialStore {
  TrackedCredentialStore(this._inner, this._tracker);
  final CredentialStore _inner;
  final EvidenceTransactionTracker _tracker;

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) => _inner.transaction(
    (transaction) => _tracker.run(() => action(transaction)),
    cancellation: cancellation,
  );
}

final class EvidenceCredentialMutation {
  const EvidenceCredentialMutation._();

  static Future<bool> forceStale(CredentialStateStore store) =>
      store.transaction((transaction) async {
        final raw = await transaction.read();
        if (raw == null) return false;
        final value = _record(raw);
        if (value == null) return false;
        value['expiresAt'] = '2000-01-01T00:00:00.000Z';
        await transaction.replace(jsonEncode(value));
        return true;
      });

  static Future<String?> generation(CredentialStateStore store) =>
      store.transaction((transaction) async {
        final raw = await transaction.read();
        if (raw == null) return null;
        return _record(raw)?['generation'] as String?;
      });

  static Future<void> seedExpiredWithoutRefresh(CredentialStateStore store) =>
      store.transaction(
        (transaction) => transaction.replace(
          jsonEncode(<String, Object?>{
            'v': 1,
            'access': 'evidence-expired-access',
            'refresh': '',
            'expiresAt': '2000-01-01T00:00:00.000Z',
            'generation': 'evidence-generation-0001',
            'account': 'evidence-account',
          }),
        ),
      );

  static Future<void> seedMalformed(CredentialStateStore store) =>
      store.transaction((transaction) => transaction.replace('{'));

  static Map<String, Object?>? _record(String raw) {
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, Object?>.from(value) : null;
    } on FormatException {
      return null;
    }
  }
}

final class PausingCredentialStore implements CredentialStore {
  PausingCredentialStore(
    this._inner, {
    required this.stateStore,
    required this.command,
    required this.phase,
  });

  final CredentialStore _inner;
  final EvidenceStateStore stateStore;
  final EvidenceCommand command;
  final EvidenceCheckpointPhase phase;

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) => _inner.transaction(
    (transaction) => action(
      _PausingTransaction(
        transaction,
        stateStore: stateStore,
        command: command,
        phase: phase,
      ),
    ),
    cancellation: cancellation,
  );
}

final class _PausingTransaction implements CredentialTransaction {
  const _PausingTransaction(
    this._inner, {
    required this.stateStore,
    required this.command,
    required this.phase,
  });

  final CredentialTransaction _inner;
  final EvidenceStateStore stateStore;
  final EvidenceCommand command;
  final EvidenceCheckpointPhase phase;

  @override
  bool get requiresReauthentication => _inner.requiresReauthentication;

  @override
  Future<void> clear() => _inner.clear();

  @override
  Future<void> clearAfterRefresh(String generation) =>
      _inner.clearAfterRefresh(generation);

  @override
  Future<void> markRefreshRisk(String generation) async {
    await _inner.markRefreshRisk(generation);
    if (phase == EvidenceCheckpointPhase.refreshRisk) {
      await _checkpoint(
        refreshResponseCount: 0,
        replacementAcknowledged: false,
        replacementGenerationVerified: false,
      );
    }
  }

  @override
  Future<String?> read() => _inner.read();

  @override
  Future<void> replace(String record) => _inner.replace(record);

  @override
  Future<void> replaceAfterRefresh(String generation, String record) async {
    if (phase == EvidenceCheckpointPhase.beforeReplacement) {
      await _checkpoint(
        refreshResponseCount: 1,
        replacementAcknowledged: false,
        replacementGenerationVerified: false,
      );
    }
    await _inner.replaceAfterRefresh(generation, record);
    if (phase == EvidenceCheckpointPhase.afterReplacement) {
      await _checkpoint(
        refreshResponseCount: 1,
        replacementAcknowledged: true,
        replacementGenerationVerified: _replacementDiffers(generation, record),
      );
    }
  }

  @override
  Future<void> restoreAfterNotDispatched(String generation) =>
      _inner.restoreAfterNotDispatched(generation);

  bool _replacementDiffers(String generation, String record) {
    try {
      final value = jsonDecode(record);
      return value is Map &&
          value['generation'] is String &&
          value['generation'] != generation;
    } on FormatException {
      return false;
    }
  }

  Future<Never> _checkpoint({
    required int refreshResponseCount,
    required bool replacementAcknowledged,
    required bool replacementGenerationVerified,
  }) async {
    await stateStore.writeCheckpoint(
      EvidenceCheckpoint(
        command: command,
        phase: phase,
        refreshResponseCount: refreshResponseCount,
        replacementAcknowledged: replacementAcknowledged,
        replacementGenerationVerified: replacementGenerationVerified,
      ),
    );
    return Completer<Never>().future;
  }
}
