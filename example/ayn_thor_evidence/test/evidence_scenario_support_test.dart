import 'dart:convert';

import 'package:ayn_thor_evidence/credential_state_store.dart';
import 'package:ayn_thor_evidence/evidence_scenario_support.dart';
import 'package:codex_auth/codex_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expired and malformed seeds recover before protected I/O', () async {
    for (final seed in <Future<void> Function(CredentialStateStore)>[
      EvidenceCredentialMutation.seedExpiredWithoutRefresh,
      EvidenceCredentialMutation.seedMalformed,
    ]) {
      final driver = _Driver();
      final store = CredentialStateStore(driver: driver);
      await seed(store);
      final transport = EvidenceTransport(_RejectingTransport());
      final status = await CodexAuthClient(
        CodexAuthOptions(store: store, transport: transport),
      ).status();

      expect(status, AuthStatus.reauthenticationRequired);
      expect(transport.refreshCount, 0);
      expect(transport.protectedIo, 0);
      expect(driver.value, isNull);
    }
  });

  test('stale mutation preserves identity and changes only expiry', () async {
    final driver = _Driver();
    final store = CredentialStateStore(driver: driver);
    final original = <String, Object?>{
      'v': 1,
      'access': 'synthetic-access',
      'refresh': 'synthetic-refresh',
      'expiresAt': '2099-01-01T00:00:00.000Z',
      'generation': 'generation-0123456789',
      'account': 'synthetic-account',
    };
    await store.transaction(
      (transaction) => transaction.replace(jsonEncode(original)),
    );

    expect(await EvidenceCredentialMutation.forceStale(store), isTrue);
    final envelope = jsonDecode(driver.value!) as Map<String, Object?>;
    final record = jsonDecode(envelope['record']! as String);
    expect(record['generation'], original['generation']);
    expect(record['expiresAt'], isNot(original['expiresAt']));
  });

  test(
    'invalid grant substitution is one-shot and does not forward input',
    () async {
      final inner = _CapturingTransport();
      final transport = EvidenceTransport(inner, substituteInvalidGrant: true);
      HttpRequestData request(String value) => HttpRequestData(
        method: 'POST',
        uri: Uri.https('auth.openai.com', '/oauth/token'),
        body: utf8.encode(
          'grant_type=refresh_token&refresh_token=$value&client_id=fixed',
        ),
      );

      await transport.send(request('first-synthetic-value'));
      await transport.send(request('second-synthetic-value'));

      expect(transport.refreshCount, 2);
      expect(transport.substitutionApplied, isTrue);
      expect(inner.firstContainedOriginal, isFalse);
      expect(inner.firstContainedSubstitute, isTrue);
      expect(inner.secondContainedOriginal, isTrue);
    },
  );
}

final class _Driver implements DurableRecordDriver {
  String? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<void> commit(String envelope) async => value = envelope;

  @override
  Future<String?> read() async => value;
}

final class _RejectingTransport implements HttpTransport {
  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) => throw StateError('unexpected transport');
}

final class _CapturingTransport implements HttpTransport {
  var calls = 0;
  var firstContainedOriginal = false;
  var firstContainedSubstitute = false;
  var secondContainedOriginal = false;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    calls++;
    final body = utf8.decode(request.body);
    if (calls == 1) {
      firstContainedOriginal = body.contains('first-synthetic-value');
      firstContainedSubstitute = body.contains(
        'evidence-invalid-refresh-value',
      );
    } else {
      secondContainedOriginal = body.contains('second-synthetic-value');
    }
    return HttpResponseData(
      400,
      const <String, String>{},
      const Stream<List<int>>.empty(),
    );
  }
}
