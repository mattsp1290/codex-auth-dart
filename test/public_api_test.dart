import 'dart:async';
import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

final class _Store implements CredentialStore {
  String? value;
  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action,
  ) => action(_Transaction(this));
}

final class _Transaction implements CredentialTransaction {
  _Transaction(this.store);
  final _Store store;
  @override
  Future<void> clear() async => store.value = null;
  @override
  Future<String?> read() async => store.value;
  @override
  Future<void> replace(String record) async => store.value = record;
}

final class _ScriptedTransport implements HttpTransport {
  _ScriptedTransport(this.responses);
  final List<Map<String, Object?>> responses;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    requests.add(request);
    final next = responses.removeAt(0);
    return HttpResponseData(
      next['status']! as int,
      const <String, String>{},
      Stream<List<int>>.value(utf8.encode(jsonEncode(next['body']))),
    );
  }
}

void main() {
  test(
    'a catalog snapshot admits exact tuples and sends only admitted fields',
    () async {
      final transport = _ScriptedTransport(<Map<String, Object?>>[
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
            'access_token': 'test-access',
            'refresh_token': 'test-refresh',
            'expires_in': 3600,
            'id_token': 'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoidGVzdC1hY2NvdW50In19.sig',
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{
            'models': <Object?>[
              <String, Object?>{
                'slug': 'gpt-5.6-sol',
                'visibility': 'list',
                'supported_in_api': true,
                'supported_reasoning_levels': <Object?>[
                  <String, String>{'effort': 'medium'},
                ],
              },
              <String, Object?>{
                'slug': 'gpt-5.6-terra',
                'visibility': 'list',
                'supported_in_api': true,
                'supported_reasoning_levels': <Object?>[
                  <String, String>{'effort': 'medium'},
                ],
              },
              <String, Object?>{
                'slug': 'gpt-5.6-luna',
                'visibility': 'list',
                'supported_in_api': true,
                'supported_reasoning_levels': <Object?>[
                  <String, String>{'effort': 'medium'},
                ],
              },
            ],
          },
        },
        <String, Object?>{
          'status': 200,
          'body': <String, Object?>{'type': 'response.completed'},
        },
      ]);
      final client = CodexAuthClient(
        CodexAuthOptions(
          store: _Store(),
          transport: transport,
          clock: () => DateTime.utc(2026),
        ),
      );

      await client.loginDevice(onPrompt: (_) {});
      final snapshot = await client.listModels(const CatalogQuery('0.154.0'));
      final admission = await client.admitModel(
        snapshot,
        'gpt-5.6-sol',
        'medium',
      );
      final stream = await client.sendResponses(
        admission,
        CodexResponsesRequest(input: 'minimal'),
      );
      await stream.bytes.drain<void>();

      expect(transport.requests, hasLength(5));
      final body = jsonDecode(
        utf8.decode(transport.requests.last.body),
      ) as Map<String, Object?>;
      expect(transport.requests.last.headers['originator'], 'codex_cli_rs');
      expect(
        transport.requests.last.headers['chatgpt-account-id'],
        'test-account',
      );
      expect(body['model'], 'gpt-5.6-sol');
      expect(body['reasoning'], <String, String>{'effort': 'medium'});
      expect(
        () => client.admitModel(snapshot, 'gpt-5.6-sol', 'low'),
        throwsA(isA<CodexAuthException>()),
      );
    },
  );
}
