import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

const _identityToken =
    'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig';

final class _Store implements CredentialStore {
  _Store({this.failReplace = false});

  final bool failReplace;
  String? value;

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) async {
    throwIfCancelled(cancellation);
    return action(_Transaction(this));
  }
}

final class _Transaction implements CredentialTransaction {
  const _Transaction(this.store);
  final _Store store;

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
  Future<void> replace(String record) async {
    if (store.failReplace) throw const CredentialStoreException();
    store.value = record;
  }

  @override
  Future<void> replaceAfterRefresh(String generation, String record) =>
      replace(record);
  @override
  Future<void> restoreAfterNotDispatched(String generation) async {}
}

final class _Response {
  _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
  var closes = 0;
}

final class _Transport implements HttpTransport {
  _Transport(this.responses);
  final List<_Response> responses;
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
      response.status,
      const <String, String>{},
      Stream<List<int>>.value(utf8.encode(jsonEncode(response.body))),
      close: () => response.closes++,
    );
  }
}

_Response _start() => _Response(200, <String, Object?>{
  'device_auth_id': 'synthetic-device',
  'user_code': 'ABCD-1234',
  'interval': 1,
});

_Response _approved() => _Response(200, <String, Object?>{
  'authorization_code': 'synthetic-code',
  'code_challenge': 'synthetic-challenge',
  'code_verifier': 'synthetic-verifier',
});

_Response _tokens() => _Response(200, <String, Object?>{
  'access_token': 'synthetic-access',
  'refresh_token': 'synthetic-refresh',
  'expires_in': 3600,
  'id_token': _identityToken,
});

CodexAuthClient _client(
  _Store store,
  _Transport transport, {
  DateTime Function()? clock,
  Future<void> Function(Duration, CancellationSignal?)? delay,
}) => CodexAuthClient(
  CodexAuthOptions(
    store: store,
    transport: transport,
    clock: clock,
    delay: delay ?? (_, _) async {},
  ),
);

void main() {
  test('cancel before device initialization performs no I/O', () async {
    final cancellation = CancellationController()..cancel();
    final transport = _Transport(<_Response>[]);

    await expectLater(
      _client(
        _Store(),
        transport,
      ).loginDevice(onPrompt: (_) {}, cancellation: cancellation),
      throwsA(isA<OperationCancelled>()),
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'cancel during poll delay performs no poll or credential write',
    () async {
      final start = _start();
      final transport = _Transport(<_Response>[start]);
      final store = _Store();
      final cancellation = CancellationController();
      final promptShown = Completer<void>();
      final login =
          _client(
            store,
            transport,
            delay: (_, signal) async {
              await signal!.whenCancelled;
              throwIfCancelled(signal);
            },
          ).loginDevice(
            onPrompt: (_) => promptShown.complete(),
            cancellation: cancellation,
          );
      await promptShown.future;
      cancellation.cancel();

      await expectLater(login, throwsA(isA<OperationCancelled>()));
      expect(transport.requests, hasLength(1));
      expect(store.value, isNull);
      expect(start.closes, 1);
    },
  );

  test('pending poll then approval persists only after exchange', () async {
    final responses = <_Response>[
      _start(),
      _Response(403, const <String, Object?>{}),
      _approved(),
      _tokens(),
    ];
    final store = _Store();
    final transport = _Transport(List<_Response>.of(responses));

    await _client(store, transport).loginDevice(onPrompt: (_) {});

    expect(
      await _client(store, _Transport(<_Response>[])).status(),
      AuthStatus.signedIn,
    );
    expect(transport.requests, hasLength(4));
    expect(responses.every((response) => response.closes == 1), isTrue);
  });

  test('deadline expiry dispatches no late poll', () async {
    var now = DateTime.utc(2026);
    final start = _start();
    final transport = _Transport(<_Response>[start]);
    final client = _client(
      _Store(),
      transport,
      clock: () => now,
      delay: (_, _) async => now = now.add(const Duration(minutes: 16)),
    );

    await expectLater(
      client.loginDevice(onPrompt: (_) {}),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.deviceAuthorizationExpired,
        ),
      ),
    );
    expect(transport.requests, hasLength(1));
    expect(start.closes, 1);
  });

  test('explicit decline maps to a finite category', () async {
    final transport = _Transport(<_Response>[
      _start(),
      _Response(400, <String, Object?>{'error': 'authorization_declined'}),
    ]);

    await expectLater(
      _client(_Store(), transport).loginDevice(onPrompt: (_) {}),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.deviceAuthorizationDeclined,
        ),
      ),
    );
  });

  test('prompt callback failure is redacted and closes its response', () async {
    const canary = 'dependency-secret-canary';
    final start = _start();
    final transport = _Transport(<_Response>[start]);

    Object? observed;
    try {
      await _client(
        _Store(),
        transport,
      ).loginDevice(onPrompt: (_) => throw StateError(canary));
    } on Object catch (error) {
      observed = error;
    }
    expect(observed, isA<CodexAuthException>());
    expect(observed.toString(), isNot(contains(canary)));
    expect(start.closes, 1);
  });

  test('uncertain durable write failure requires local cleanup', () async {
    final responses = <_Response>[_start(), _approved(), _tokens()];
    final transport = _Transport(List<_Response>.of(responses));

    await expectLater(
      _client(
        _Store(failReplace: true),
        transport,
      ).loginDevice(onPrompt: (_) {}),
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
    expect(responses.every((response) => response.closes == 1), isTrue);
  });
}
