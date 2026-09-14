import 'dart:convert';

import 'package:test/test.dart';

import '../tool/evidence_schema.dart';

Map<String, Object?> _record() => <String, Object?>{
  'schemaVersion': 1,
  'packageCommit': 'a' * 40,
  'apkDigest': 'b' * 64,
  'flavor': 'evidence',
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
    'gradle': '8.0',
    'codex': '0.1',
  },
  'rows': EvidenceSchema.rowIds
      .map(
        (id) => <String, Object?>{
          'id': id,
          'state': 'fail',
          'predicates': <String, Object?>{},
          'hermeticTest': null,
        },
      )
      .toList(),
  'tuples': EvidenceSchema.tupleSlugs
      .map(
        (slug) => <String, Object?>{
          'slug': slug,
          'effort': 'medium',
          'admitted': true,
          'requestAccepted': true,
          'executedIdentityVerified': true,
        },
      )
      .toList(),
  'redirects': <Object?>[
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
          'sourceShape': _sourceShape(requestClass),
          'targetShape': _emptyShape(),
          'peerClosed': true,
        },
  ],
};

Map<String, bool> _sourceShape(String requestClass) => <String, bool>{
  'authorization':
      requestClass == 'catalog-bearer' || requestClass == 'responses-bearer',
  'deviceAuthId': requestClass == 'device-json',
  'userCode': requestClass == 'device-json',
  'authorizationCode': requestClass == 'authorization-code-form',
  'refreshToken': requestClass == 'refresh-token-form',
};

Map<String, bool> _emptyShape() => <String, bool>{
  'authorization': false,
  'deviceAuthId': false,
  'userCode': false,
  'authorizationCode': false,
  'refreshToken': false,
};

String _rawResult({required String nonce}) =>
    '''
{"schemaVersion":1,"scenario":"local-logout","packageCommit":"${'a' * 40}","flavor":"evidence","nonce":"$nonce","state":"pass","recovery":"signed-out","protectedIo":0,"predicates":{"clearAcknowledged":true,"signedOut":true,"noRemoteRevocation":true}}
''';

void main() {
  test('accepts a complete finite evidence record', () {
    expect(EvidenceSchema.validateRenderable(_record()), isNotNull);
  });

  test('rejects unknown keys and unsafe non-inducible rows', () {
    final unknown = _record()..['nonce'] = 'nope';
    expect(
      () => EvidenceSchema.validateRenderable(unknown),
      throwsFormatException,
    );
    final unsafe = _record();
    (unsafe['rows']! as List<Object?>).first = <String, Object?>{
      'id': 'approved-login',
      'state': 'not-safely-inducible',
      'predicates': <String, Object?>{},
      'hermeticTest': 'device-login-cancel',
    };
    expect(
      () => EvidenceSchema.validateRenderable(unsafe),
      throwsFormatException,
    );
  });

  test('rejects redirect leakage and incomplete exact tuple evidence', () {
    final leaked = _record();
    (leaked['redirects']! as List<Object?>).first = <String, Object?>{
      'requestClass': 'device-json',
      'status': 301,
      'sourceHits': 1,
      'targetHits': 1,
      'sourceShape': <String, Object?>{'expected': true},
      'targetShape': <String, Object?>{'expected': true},
      'peerClosed': true,
    };
    expect(
      () => EvidenceSchema.validateRenderable(leaked),
      throwsFormatException,
    );
  });

  test('rejects invented and incomplete pass predicates', () {
    final invented = _record();
    (invented['rows']! as List<Object?>).first = <String, Object?>{
      'id': 'apk-device-provenance',
      'state': 'fail',
      'predicates': <String, Object?>{'provenanceMatch': true},
      'hermeticTest': null,
    };
    expect(
      () => EvidenceSchema.validateRenderable(invented),
      throwsFormatException,
    );

    final incomplete = _record();
    (incomplete['rows']! as List<Object?>).first = <String, Object?>{
      'id': 'apk-device-provenance',
      'state': 'pass',
      'predicates': <String, Object?>{'physicalDevice': true},
      'hermeticTest': null,
    };
    expect(
      () => EvidenceSchema.validateRenderable(incomplete),
      throwsFormatException,
    );
  });

  test('requires the exact hermetic test for safe non-inducible rows', () {
    final invalid = _record();
    final rows = invalid['rows']! as List<Object?>;
    final index = rows.indexWhere(
      (row) => (row as Map<String, Object?>)['id'] == 'cancel-login',
    );
    rows[index] = <String, Object?>{
      'id': 'cancel-login',
      'state': 'not-safely-inducible',
      'predicates': <String, Object?>{},
      'hermeticTest': 'different-test',
    };
    expect(
      () => EvidenceSchema.validateRenderable(invalid),
      throwsFormatException,
    );
  });

  test('raw result rejects stale nonces and unknown fields', () {
    expect(
      () => EvidenceSchema.validateRawResult(
        _rawResult(nonce: 'd' * 64),
        scenario: 'local-logout',
        packageCommit: 'a' * 40,
        nonce: 'e' * 64,
      ),
      throwsFormatException,
    );
    expect(
      () => EvidenceSchema.validateRawResult(
        '${_rawResult(nonce: 'd' * 64).trimRight().substring(0, _rawResult(nonce: 'd' * 64).trimRight().length - 1)},"extra":true}',
        scenario: 'local-logout',
        packageCommit: 'a' * 40,
        nonce: 'd' * 64,
      ),
      throwsFormatException,
    );
  });

  test('raw result diagnostics expose only closed mismatch classes', () {
    expect(
      EvidenceSchema.diagnoseRawResult(
        _rawResult(nonce: 'd' * 64),
        scenario: 'local-logout',
        packageCommit: 'a' * 40,
        nonce: 'e' * 64,
      ),
      RawEvidenceRejection.nonce,
    );
  });

  test('raw pass rejects a false or missing scenario predicate', () {
    final value = jsonDecode(_rawResult(nonce: 'd' * 64));
    final predicates =
        (value as Map<String, Object?>)['predicates']! as Map<String, Object?>;
    predicates['signedOut'] = false;

    expect(
      EvidenceSchema.diagnoseRawResult(
        jsonEncode(value),
        scenario: 'local-logout',
        packageCommit: 'a' * 40,
        nonce: 'd' * 64,
      ),
      RawEvidenceRejection.predicates,
    );
  });
}
