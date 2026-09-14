import 'package:test/test.dart';

import '../tool/evidence_schema.dart';
import '../tool/src/evidence_assembler.dart';
import '../tool/src/evidence_renderer.dart';

Map<String, Object?> _input() => <String, Object?>{
  'schemaVersion': 1,
  'packageCommit': 'a' * 40,
  'apkDigest': 'b' * 64,
  'accountCategory': 'ChatGPT Plus',
  'clientVersion': '0.154.0',
  'protocolCommit': 'c' * 40,
  'toolchain': <String, Object?>{
    'host': 'macOS',
    'device': 'ayn-thor',
    'flutter': '3.0',
    'dart': '3.13',
    'androidSdk': '35',
    'jdk': '17',
    'gradle': '9.3',
    'codex': '0.154.0',
  },
  'results': <Object?>[
    for (final scenario in <String>[
      ...EvidenceSchema.rawPassValues.keys.where(
        (scenario) => scenario != 'expired-login',
      ),
    ])
      <String, Object?>{
        'device': 'ayn-thor',
        'scenario': scenario,
        'state': 'pass',
        'recovery': 'signed-in',
        'protectedIo': 0,
        'predicates': Map<String, Object?>.from(
          EvidenceSchema.rawPassValues[scenario]!,
        ),
        if (scenario == 'redirect-matrix') 'redirects': _redirects(),
      },
  ],
};

List<Object?> _redirects() => <Object?>[
  for (final requestClass in <String>[
    'device-json',
    'authorization-code-form',
    'refresh-token-form',
    'catalog-bearer',
    'responses-bearer',
  ])
    for (final status in <int>[301, 302, 303, 307, 308])
      <String, Object?>{
        'requestClass': requestClass,
        'status': status,
        'sourceHits': 1,
        'targetHits': 0,
        'sourceShape': <String, bool>{
          'authorization':
              requestClass == 'catalog-bearer' ||
              requestClass == 'responses-bearer',
          'deviceAuthId': requestClass == 'device-json',
          'userCode': requestClass == 'device-json',
          'authorizationCode': requestClass == 'authorization-code-form',
          'refreshToken': requestClass == 'refresh-token-form',
        },
        'targetShape': const <String, bool>{
          'authorization': false,
          'deviceAuthId': false,
          'userCode': false,
          'authorizationCode': false,
          'refreshToken': false,
        },
        'peerClosed': true,
      },
];

void main() {
  test('assembles one complete strict renderable record', () {
    final assembled = assembleEvidence(_input());

    expect(assembled['rows'], hasLength(EvidenceSchema.rowIds.length));
    expect(assembled['tuples'], hasLength(EvidenceSchema.tupleSlugs.length));
    expect(assembled['redirects'], hasLength(25));
    final markdown = renderEvidenceMarkdown(assembled);
    expect(markdown, contains('processChanged=true'));
    expect(markdown, contains('| gpt-5.6-sol | medium | true | true | true |'));
    expect(markdown, isNot(contains('nonce')));
  });

  test('rejects a missing or duplicate runner result', () {
    final missing = _input();
    (missing['results']! as List).removeLast();
    expect(() => assembleEvidence(missing), throwsFormatException);

    final duplicate = _input();
    final results = duplicate['results']! as List;
    results.add(results.first);
    expect(() => assembleEvidence(duplicate), throwsFormatException);
  });

  test('rejects a false pass predicate during final semantic validation', () {
    final input = _input();
    final result = (input['results']! as List).cast<Map>().firstWhere(
      (item) => item['scenario'] == 'local-logout',
    );
    (result['predicates']! as Map)['signedOut'] = false;

    expect(() => assembleEvidence(input), throwsFormatException);
  });
}
