import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

final class _RiskStore implements CredentialStore {
  String? value;
  String? risk;
  var failMark = false;
  var failRestore = false;
  var failClear = false;
  var failClearAfter = false;
  var commitThenFailReplace = false;
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    if (cancellation?.isCancelled ?? false) throw OperationCancelled();
    try {
      return await action(_RiskTransaction(this));
    } finally {
      release.complete();
    }
  }
}

final class _RiskTransaction implements CredentialTransaction {
  const _RiskTransaction(this.store);
  final _RiskStore store;
  @override
  bool get requiresReauthentication => store.risk != null;
  @override
  Future<void> clear() async {
    if (store.failClear) throw const CredentialStoreException();
    store.value = null;
  }

  @override
  Future<void> clearAfterRefresh(String generation) async {
    if (store.failClearAfter) throw const CredentialStoreException();
    if (store.risk != generation) throw const CredentialStoreException();
    store.risk = null;
    store.value = null;
  }

  @override
  Future<void> markRefreshRisk(String generation) async {
    if (store.failMark) throw const CredentialStoreException();
    store.risk = generation;
  }

  @override
  Future<String?> read() async => store.value;
  @override
  Future<void> replace(String record) async => store.value = record;
  @override
  Future<void> replaceAfterRefresh(String generation, String record) async {
    if (store.risk != generation) throw const CredentialStoreException();
    store.risk = null;
    store.value = record;
    if (store.commitThenFailReplace) throw const CredentialStoreException();
  }

  @override
  Future<void> restoreAfterNotDispatched(String generation) async {
    if (store.failRestore) throw const CredentialStoreException();
    if (store.risk != generation) throw const CredentialStoreException();
    store.risk = null;
  }
}

final class _Transport implements HttpTransport {
  _Transport(this._responses, {this.refreshFailure});
  final List<Map<String, Object?>> _responses;
  final HttpTransportException? refreshFailure;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    requests.add(request);
    if (request.uri.path == '/oauth/token' &&
        requests.where((item) => item.uri.path == '/oauth/token').length == 2 &&
        refreshFailure != null) {
      throw refreshFailure!;
    }
    final response = _responses.removeAt(0);
    final body = response['body'];
    return HttpResponseData(
      response['status']! as int,
      const <String, String>{},
      Stream<List<int>>.value(
        utf8.encode(body is String ? body : jsonEncode(body)),
      ),
    );
  }
}

Map<String, Object?> _response(int status, Map<String, Object?> body) =>
    <String, Object?>{'status': status, 'body': body};

List<Map<String, Object?>> _loginResponses() => <Map<String, Object?>>[
  _response(200, <String, Object?>{
    'device_auth_id': 'opaque',
    'user_code': 'ABCD-1234',
    'interval': 1,
  }),
  _response(200, <String, Object?>{
    'authorization_code': 'opaque',
    'code_challenge': 'challenge',
    'code_verifier': 'verifier',
  }),
  _response(200, <String, Object?>{
    'access_token': 'first-access',
    'refresh_token': 'first-refresh',
    'expires_in': 1,
    'id_token': 'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig',
  }),
];

String _idTokenFor(String account) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode(<String, Object?>{
      'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': account},
    }))).replaceAll('=', '')}.sig';

void main() {
  Future<CodexAuthClient> login(
    _RiskStore store,
    _Transport transport,
    DateTime Function() clock,
  ) async {
    final client = CodexAuthClient(
      CodexAuthOptions(
        store: store,
        transport: transport,
        clock: clock,
        delay: (_, _) async {},
      ),
    );
    await client.loginDevice(onPrompt: (_) {});
    return client;
  }

  test(
    'proven pre-dispatch refresh failure retains durable credentials',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore();
      final transport = _Transport(
        _loginResponses(),
        refreshFailure: const HttpTransportException(
          HttpDispatchPhase.notDispatched,
          HttpTransportOutcome.failed,
        ),
      );
      final client = await login(store, transport, () => now);
      now = now.add(const Duration(minutes: 3));
      await expectLater(
        client.listModels(const CatalogQuery('0.154.0')),
        throwsA(
          isA<CodexAuthException>()
              .having(
                (error) => error.category,
                'category',
                CodexAuthErrorCategory.requestFailed,
              )
              .having((error) => error.canRetry, 'canRetry', isTrue),
        ),
      );
      expect(store.value, isNotNull);
      expect(store.risk, isNull);
      expect(
        transport.requests.where(
          (request) => request.uri.path.contains('models'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'refresh-risk commit failure blocks dispatch and requires cleanup',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore();
      final transport = _Transport(_loginResponses());
      final client = await login(store, transport, () => now);
      store.failMark = true;
      now = now.add(const Duration(minutes: 3));

      await expectLater(
        client.listModels(const CatalogQuery('0.154.0')),
        throwsA(
          isA<CodexAuthException>()
              .having(
                (error) => error.category,
                'category',
                CodexAuthErrorCategory.localCleanupRequired,
              )
              .having((error) => error.cleanupRequired, 'cleanup', isTrue),
        ),
      );
      expect(
        transport.requests.where(
          (request) => request.uri.path.contains('models'),
        ),
        isEmpty,
      );
      expect(
        transport.requests.where(
          (request) => request.uri.path == '/oauth/token',
        ),
        hasLength(1),
      );
    },
  );

  test('failed pre-dispatch rollback requires explicit cleanup', () async {
    var now = DateTime.utc(2026);
    final store = _RiskStore()..failRestore = true;
    final transport = _Transport(
      _loginResponses(),
      refreshFailure: const HttpTransportException(
        HttpDispatchPhase.notDispatched,
        HttpTransportOutcome.failed,
      ),
    );
    final client = await login(store, transport, () => now);
    now = now.add(const Duration(minutes: 3));

    await expectLater(
      client.listModels(const CatalogQuery('0.154.0')),
      throwsA(
        isA<CodexAuthException>()
            .having(
              (error) => error.category,
              'category',
              CodexAuthErrorCategory.localCleanupRequired,
            )
            .having((error) => error.cleanupRequired, 'cleanup', isTrue),
      ),
    );
    expect(store.risk, isNotNull);
    expect(
      transport.requests.where(
        (request) => request.uri.path.contains('models'),
      ),
      isEmpty,
    );
  });

  test('malformed post-dispatch refresh clears before protected I/O', () async {
    var now = DateTime.utc(2026);
    final store = _RiskStore();
    final transport = _Transport(<Map<String, Object?>>[
      ..._loginResponses(),
      _response(200, <String, Object?>{})..['body'] = '{',
    ]);
    final client = await login(store, transport, () => now);
    now = now.add(const Duration(minutes: 3));

    await expectLater(
      client.listModels(const CatalogQuery('0.154.0')),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.reauthenticationRequired,
        ),
      ),
    );
    expect(store.value, isNull);
    expect(store.risk, isNull);
    expect(
      transport.requests.where(
        (request) => request.uri.path.contains('models'),
      ),
      isEmpty,
    );
  });

  for (final invalidRefresh in <Map<String, Object?>>[
    <String, Object?>{
      'access_token': 'replacement-access',
      'refresh_token': 'replacement-refresh',
      'expires_in': 0,
    },
    <String, Object?>{
      'access_token': 'replacement-access',
      'refresh_token': 'replacement-refresh',
      'expires_in': 3600,
      'id_token': _idTokenFor('different-account'),
    },
  ]) {
    test(
      'invalid refresh identity or expiry clears before protected I/O',
      () async {
        var now = DateTime.utc(2026);
        final store = _RiskStore();
        final transport = _Transport(<Map<String, Object?>>[
          ..._loginResponses(),
          _response(200, invalidRefresh),
        ]);
        final client = await login(store, transport, () => now);
        now = now.add(const Duration(minutes: 3));

        await expectLater(
          client.listModels(const CatalogQuery('0.154.0')),
          throwsA(
            isA<CodexAuthException>().having(
              (error) => error.category,
              'category',
              CodexAuthErrorCategory.reauthenticationRequired,
            ),
          ),
        );
        expect(store.value, isNull);
        expect(store.risk, isNull);
        expect(
          transport.requests.where(
            (request) => request.uri.path.contains('models'),
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'failed conditional cleanup is explicit and forbids protected I/O',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore()..failClearAfter = true;
      final transport = _Transport(
        _loginResponses(),
        refreshFailure: const HttpTransportException(
          HttpDispatchPhase.possiblyDispatched,
          HttpTransportOutcome.failed,
        ),
      );
      final client = await login(store, transport, () => now);
      now = now.add(const Duration(minutes: 3));

      await expectLater(
        client.listModels(const CatalogQuery('0.154.0')),
        throwsA(
          isA<CodexAuthException>()
              .having(
                (error) => error.category,
                'category',
                CodexAuthErrorCategory.localCleanupRequired,
              )
              .having((error) => error.cleanupRequired, 'cleanup', isTrue),
        ),
      );
      expect(
        transport.requests.where(
          (request) => request.uri.path.contains('models'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'replacement committed but not reported recovers as signed in',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore()..commitThenFailReplace = true;
      final transport = _Transport(<Map<String, Object?>>[
        ..._loginResponses(),
        _response(200, <String, Object?>{
          'access_token': 'replacement-access',
          'refresh_token': 'replacement-refresh',
          'expires_in': 3600,
        }),
      ]);
      final client = await login(store, transport, () => now);
      now = now.add(const Duration(minutes: 3));

      await expectLater(
        client.listModels(const CatalogQuery('0.154.0')),
        throwsA(
          isA<CodexAuthException>().having(
            (error) => error.cleanupRequired,
            'cleanup',
            isTrue,
          ),
        ),
      );
      expect(store.risk, isNull);
      expect(store.value, contains('replacement-access'));
      expect(
        await CodexAuthClient(
          CodexAuthOptions(
            store: store,
            transport: _Transport(<Map<String, Object?>>[]),
          ),
        ).status(),
        AuthStatus.signedIn,
      );
    },
  );

  test(
    'malformed stored credentials with failed cleanup are explicit',
    () async {
      final store = _RiskStore()
        ..value = '{'
        ..failClear = true;
      final transport = _Transport(<Map<String, Object?>>[]);
      final client = CodexAuthClient(
        CodexAuthOptions(store: store, transport: transport),
      );

      await expectLater(
        client.status(),
        throwsA(
          isA<CodexAuthException>()
              .having(
                (error) => error.category,
                'category',
                CodexAuthErrorCategory.localCleanupRequired,
              )
              .having((error) => error.cleanupRequired, 'cleanup', isTrue),
        ),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'ambiguous refresh failure clears the old record before protected I/O',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore();
      final transport = _Transport(
        _loginResponses(),
        refreshFailure: const HttpTransportException(
          HttpDispatchPhase.possiblyDispatched,
          HttpTransportOutcome.responseHeaderTimeout,
        ),
      );
      final client = await login(store, transport, () => now);
      now = now.add(const Duration(minutes: 3));
      await expectLater(
        client.listModels(const CatalogQuery('0.154.0')),
        throwsA(
          isA<CodexAuthException>().having(
            (error) => error.category,
            'category',
            CodexAuthErrorCategory.reauthenticationRequired,
          ),
        ),
      );
      expect(store.value, isNull);
      expect(store.risk, isNull);
      expect(
        transport.requests.where(
          (request) => request.uri.path.contains('models'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'successful refresh may retain an omitted replacement refresh token',
    () async {
      var now = DateTime.utc(2026);
      final store = _RiskStore();
      final responses = _loginResponses()
        ..addAll(<Map<String, Object?>>[
          _response(200, <String, Object?>{
            'access_token': 'rotated-access',
            'expires_in': 3600,
          }),
          _response(200, <String, Object?>{'models': <Object?>[]}),
        ]);
      final transport = _Transport(responses);
      final client = await login(store, transport, () => now);
      final oldGeneration =
          (jsonDecode(store.value!) as Map<String, Object?>)['generation'];
      now = now.add(const Duration(minutes: 3));
      await client.listModels(const CatalogQuery('0.154.0'));
      final newGeneration =
          (jsonDecode(store.value!) as Map<String, Object?>)['generation'];
      expect(store.value, contains('first-refresh'));
      expect(store.value, contains('rotated-access'));
      expect(newGeneration, isNot(oldGeneration));
      expect(store.risk, isNull);
    },
  );
}
