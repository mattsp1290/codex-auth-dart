import 'dart:async';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

import 'support/auth_fixture.dart';

Future<(CodexAuthClient, ScriptedTransport, TestResponse, ModelAdmission)>
_fixture(TestResponse response) async {
  final transport = ScriptedTransport(<TestResponse>[
    ...successfulLoginResponses(),
    TestResponse.json(200, <String, Object?>{
      'models': <Object?>[
        <String, Object?>{
          'slug': 'gpt-5.6-sol',
          'visibility': 'list',
          'supported_in_api': true,
          'supported_reasoning_levels': <Object?>[
            <String, String>{'effort': 'medium'},
          ],
        },
      ],
    }),
    response,
  ]);
  final client = testClient(
    TestCredentialStore(),
    transport,
    TestClock(DateTime.utc(2026)),
  );
  await loginTestClient(client);
  final catalog = await client.listModels(const CatalogQuery('0.154.0'));
  final admission = await client.admitModel(catalog, 'gpt-5.6-sol', 'medium');
  return (client, transport, response, admission);
}

void main() {
  test('successful stream closes its transport exactly once at EOF', () async {
    final response = TestResponse(200, Stream<List<int>>.value(<int>[1, 2]));
    final (client, _, _, admission) = await _fixture(response);

    final stream = await client.sendResponses(
      admission,
      CodexResponsesRequest(input: 'synthetic'),
    );
    expect(await stream.bytes.expand((chunk) => chunk).toList(), <int>[1, 2]);
    await stream.close();
    await stream.close();

    expect(response.closes, 1);
  });

  test('caller close cancels an active stream exactly once', () async {
    final source = StreamController<List<int>>();
    addTearDown(source.close);
    final response = TestResponse(200, source.stream);
    final (client, _, _, admission) = await _fixture(response);
    final stream = await client.sendResponses(
      admission,
      CodexResponsesRequest(input: 'synthetic'),
    );
    final subscription = stream.bytes.listen((_) {});
    source.add(<int>[1]);

    await stream.close();
    await subscription.cancel();
    await stream.close();
    expect(response.closes, 1);
  });

  test('non-success response closes before returning a finite error', () async {
    final response = TestResponse.json(500, const <String, Object?>{});
    final (client, _, _, admission) = await _fixture(response);

    await expectLater(
      client.sendResponses(
        admission,
        CodexResponsesRequest(input: 'synthetic'),
      ),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.requestFailed,
        ),
      ),
    );
    expect(response.closes, 1);
  });

  test('caller cannot override model or reasoning and causes no I/O', () async {
    final response = TestResponse.json(200, const <String, Object?>{});
    final (client, transport, _, admission) = await _fixture(response);
    final before = transport.requests.length;

    for (final options in <Map<String, Object?>>[
      <String, Object?>{'model': 'different'},
      <String, Object?>{
        'reasoning': <String, String>{'effort': 'low'},
      },
    ]) {
      await expectLater(
        client.sendResponses(
          admission,
          CodexResponsesRequest(input: 'synthetic', options: options),
        ),
        throwsA(
          isA<CodexAuthException>().having(
            (error) => error.category,
            'category',
            CodexAuthErrorCategory.protocolFailure,
          ),
        ),
      );
    }
    expect(transport.requests, hasLength(before));
  });
}
