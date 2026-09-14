import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';

const syntheticIdentityToken =
    'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig';

final class TestClock {
  TestClock(this.value);
  DateTime value;
  DateTime call() => value;
}

final class TestCredentialStore implements CredentialStore {
  String? value;
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) async {
    final prior = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await prior;
    throwIfCancelled(cancellation);
    try {
      return await action(_TestTransaction(this));
    } finally {
      release.complete();
    }
  }
}

final class _TestTransaction implements CredentialTransaction {
  const _TestTransaction(this.store);
  final TestCredentialStore store;
  @override
  bool get requiresReauthentication => false;
  @override
  Future<void> clear() async => store.value = null;
  @override
  Future<void> clearAfterRefresh(String generation) => clear();
  @override
  Future<void> markRefreshRisk(String generation) async {}
  @override
  Future<String?> read() async => store.value;
  @override
  Future<void> replace(String record) async => store.value = record;
  @override
  Future<void> replaceAfterRefresh(String generation, String record) =>
      replace(record);
  @override
  Future<void> restoreAfterNotDispatched(String generation) async {}
}

final class TestResponse {
  TestResponse(this.statusCode, this.body);

  factory TestResponse.json(int statusCode, Map<String, Object?> body) =>
      TestResponse(
        statusCode,
        Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      );

  final int statusCode;
  final Stream<List<int>> body;
  var closes = 0;
}

final class ScriptedTransport implements HttpTransport {
  ScriptedTransport(Iterable<TestResponse> responses)
    : responses = List<TestResponse>.of(responses);

  final List<TestResponse> responses;
  final requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    throwIfCancelled(cancellation);
    requests.add(request);
    final response = responses.removeAt(0);
    return HttpResponseData(
      response.statusCode,
      const <String, String>{},
      response.body,
      close: () => response.closes++,
    );
  }
}

List<TestResponse> successfulLoginResponses() => <TestResponse>[
  TestResponse.json(200, <String, Object?>{
    'device_auth_id': 'synthetic-device',
    'user_code': 'ABCD-1234',
    'interval': 1,
  }),
  TestResponse.json(200, <String, Object?>{
    'authorization_code': 'synthetic-code',
    'code_challenge': 'synthetic-challenge',
    'code_verifier': 'synthetic-verifier',
  }),
  TestResponse.json(200, <String, Object?>{
    'access_token': 'synthetic-access',
    'refresh_token': 'synthetic-refresh',
    'expires_in': 3600,
    'id_token': syntheticIdentityToken,
  }),
];

CodexAuthClient testClient(
  TestCredentialStore store,
  ScriptedTransport transport,
  TestClock clock,
) => CodexAuthClient(
  CodexAuthOptions(
    store: store,
    transport: transport,
    clock: clock.call,
    delay: (_, _) async {},
  ),
);

Future<void> loginTestClient(CodexAuthClient client) =>
    client.loginDevice(onPrompt: (_) {});
