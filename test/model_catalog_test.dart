import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

import 'support/auth_fixture.dart';

Map<String, Object?> _listed(String slug, List<String> efforts) =>
    <String, Object?>{
      'slug': slug,
      'visibility': 'list',
      'supported_in_api': true,
      'supported_reasoning_levels': efforts
          .map((effort) => <String, String>{'effort': effort})
          .toList(),
    };

void main() {
  test('catalog admits only exact visible API tuples from one fetch', () async {
    final login = successfulLoginResponses();
    final catalog = TestResponse.json(200, <String, Object?>{
      'models': <Object?>[
        _listed('gpt-5.6-sol', <String>['medium']),
        _listed('gpt-5.6-terra', <String>['medium']),
        _listed('gpt-5.6-luna', <String>['medium']),
        _listed('gpt-5.6-sol', <String>['medium']),
        <String, Object?>{
          ..._listed('hidden-model', <String>['medium']),
          'visibility': 'hide',
        },
        <String, Object?>{
          ..._listed('non-api-model', <String>['medium']),
          'supported_in_api': false,
        },
        <String, Object?>{'slug': 'malformed'},
      ],
    });
    final transport = ScriptedTransport(<TestResponse>[...login, catalog]);
    final store = TestCredentialStore();
    final clock = TestClock(DateTime.utc(2026));
    final client = testClient(store, transport, clock);
    await loginTestClient(client);

    final snapshot = await client.listModels(const CatalogQuery('0.154.0'));
    for (final slug in <String>[
      'gpt-5.6-sol',
      'gpt-5.6-terra',
      'gpt-5.6-luna',
    ]) {
      await client.admitModel(snapshot, slug, 'medium');
    }
    await expectLater(
      client.admitModel(snapshot, 'hidden-model', 'medium'),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.modelUnavailable,
        ),
      ),
    );
    await expectLater(
      client.admitModel(snapshot, 'gpt-5.6-sol', 'low'),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.effortUnavailable,
        ),
      ),
    );
    expect(
      transport.requests.where(
        (request) => request.uri.path.contains('models'),
      ),
      hasLength(1),
    );
    expect(catalog.closes, 1);
  });

  test('catalog admission expires without protected I/O', () async {
    final transport = ScriptedTransport(<TestResponse>[
      ...successfulLoginResponses(),
      TestResponse.json(200, <String, Object?>{
        'models': <Object?>[
          _listed('gpt-5.6-sol', <String>['medium']),
        ],
      }),
    ]);
    final store = TestCredentialStore();
    final clock = TestClock(DateTime.utc(2026));
    final client = testClient(store, transport, clock);
    await loginTestClient(client);
    final snapshot = await client.listModels(const CatalogQuery('0.154.0'));
    final before = transport.requests.length;
    clock.value = clock.value.add(const Duration(minutes: 6));

    await expectLater(
      client.admitModel(snapshot, 'gpt-5.6-sol', 'medium'),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.staleAdmission,
        ),
      ),
    );
    expect(transport.requests, hasLength(before));
  });

  test('credential generation change invalidates an admission', () async {
    final transport = ScriptedTransport(<TestResponse>[
      ...successfulLoginResponses(),
      TestResponse.json(200, <String, Object?>{
        'models': <Object?>[
          _listed('gpt-5.6-sol', <String>['medium']),
        ],
      }),
    ]);
    final store = TestCredentialStore();
    final clock = TestClock(DateTime.utc(2026));
    final client = testClient(store, transport, clock);
    await loginTestClient(client);
    final snapshot = await client.listModels(const CatalogQuery('0.154.0'));
    final record = jsonDecode(store.value!) as Map<String, Object?>;
    record['generation'] = 'different-generation-000000000000';
    store.value = jsonEncode(record);
    final before = transport.requests.length;

    await expectLater(
      client.admitModel(snapshot, 'gpt-5.6-sol', 'medium'),
      throwsA(
        isA<CodexAuthException>().having(
          (error) => error.category,
          'category',
          CodexAuthErrorCategory.staleAdmission,
        ),
      ),
    );
    expect(transport.requests, hasLength(before));
  });
}
