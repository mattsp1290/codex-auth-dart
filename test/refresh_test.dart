import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

final class _SerialStore implements CredentialStore {
  String? value;
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
    try {
      return await action(_SerialTransaction(this));
    } finally {
      release.complete();
    }
  }
}

final class _SerialTransaction implements CredentialTransaction {
  const _SerialTransaction(this.store);
  final _SerialStore store;
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

final class _Transport implements HttpTransport {
  _Transport(this._responses);
  final List<Map<String, Object?>> _responses;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    requests.add(request);
    final response = _responses.removeAt(0);
    return HttpResponseData(
      response['status']! as int,
      const <String, String>{},
      Stream<List<int>>.value(utf8.encode(jsonEncode(response['body']))),
    );
  }
}

void main() {
  test(
    'two clients serialize a rotating refresh and both observe replacement',
    () async {
      var now = DateTime.utc(2026);
      final store = _SerialStore();
      final transport = _Transport(<Map<String, Object?>>[
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'device_auth_id': 'opaque',
            'user_code': 'ABCD-1234',
            'interval': 1,
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'authorization_code': 'opaque',
            'code_challenge': 'challenge',
            'code_verifier': 'verifier',
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'access_token': 'first-access',
            'refresh_token': 'first-refresh',
            'expires_in': 1,
            'id_token': 'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig',
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'expires_in': 3600,
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{'models': <Object?>[]},
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{'models': <Object?>[]},
        },
      ]);
      CodexAuthClient makeClient() => CodexAuthClient(
        CodexAuthOptions(store: store, transport: transport, clock: () => now),
      );
      final first = makeClient();
      await first.loginDevice(onPrompt: (_) {});
      now = now.add(const Duration(minutes: 3));
      final second = makeClient();
      await Future.wait(<Future<Object?>>[
        first.listModels(const CatalogQuery('0.154.0')),
        second.listModels(const CatalogQuery('0.154.0')),
      ]);
      final refreshes = transport.requests
          .where((request) => request.uri.path == '/oauth/token')
          .toList();
      expect(
        refreshes,
        hasLength(2),
      ); // login exchange + one serialized refresh.
      expect(
        utf8.decode(refreshes.last.body),
        contains('refresh_token=first-refresh'),
      );
      expect(
        transport.requests.where(
          (request) =>
              request.headers['authorization'] == 'Bearer rotated-access',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'invalid grant clears credentials and makes no protected request',
    () async {
      var now = DateTime.utc(2026);
      final store = _SerialStore();
      final transport = _Transport(<Map<String, Object?>>[
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'device_auth_id': 'opaque',
            'user_code': 'ABCD-1234',
            'interval': 1,
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'authorization_code': 'opaque',
            'code_challenge': 'challenge',
            'code_verifier': 'verifier',
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_in': 1,
            'id_token': 'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig',
          },
        },
        <String, Object?>{
          'status': 400,
          'body': <String, Object?>{'error': 'invalid_grant'},
        },
      ]);
      final client = CodexAuthClient(
        CodexAuthOptions(store: store, transport: transport, clock: () => now),
      );
      await client.loginDevice(onPrompt: (_) {});
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
      expect(
        transport.requests.where(
          (request) => request.uri.path.contains('models'),
        ),
        isEmpty,
      );
    },
  );
}
