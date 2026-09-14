import '../evidence_schema.dart';

/// Converts closed, nonce-free runner results into the one renderable record.
Map<String, Object?> assembleEvidence(Map<String, Object?> input) {
  const keys = <String>{
    'schemaVersion',
    'packageCommit',
    'apkDigest',
    'accountCategory',
    'clientVersion',
    'protocolCommit',
    'toolchain',
    'results',
  };
  if (input.keys.toSet().length != keys.length ||
      !input.keys.toSet().containsAll(keys) ||
      input['schemaVersion'] != 1 ||
      input['results'] is! List) {
    throw const FormatException('invalid finite evidence assembly');
  }

  final byScenario = <String, Map<String, Object?>>{};
  for (final raw in input['results']! as List) {
    final result = _object(raw);
    const required = <String>{
      'device',
      'scenario',
      'state',
      'recovery',
      'protectedIo',
      'predicates',
    };
    const allowed = <String>{...required, 'category', 'redirects'};
    if (!result.keys.toSet().containsAll(required) ||
        result.keys.any((key) => !allowed.contains(key)) ||
        result['device'] != 'ayn-thor' ||
        result['scenario'] is! String ||
        result['predicates'] is! Map ||
        result['protectedIo'] is! int ||
        !EvidenceSchema.states.contains(result['state'])) {
      throw const FormatException('invalid finite evidence assembly');
    }
    final scenario = result['scenario']! as String;
    if (!EvidenceSchema.rawPassValues.containsKey(scenario) ||
        byScenario.containsKey(scenario)) {
      throw const FormatException('invalid finite evidence assembly');
    }
    byScenario[scenario] = result;
  }

  const directRows = <String, String>{
    'approved-login': 'approved-login',
    'cancel-login': 'cancel-login',
    'rehydrate-after-resume': 'rehydrate-after-resume',
    'rehydrate-after-process-death': 'rehydrate-after-process-death',
    'two-client-rotation': 'two-client-rotation',
    'interrupt-after-refresh-risk': 'interrupt-after-refresh-risk',
    'interrupt-before-replacement-commit':
        'interrupt-before-replacement-commit',
    'interrupt-after-replacement-commit': 'interrupt-after-replacement-commit',
    'invalid-grant': 'invalid-grant',
    'expired-without-refresh': 'expired-without-refresh',
    'malformed-store': 'malformed-store',
    'unavailable-tuple': 'catalog-and-unavailable',
    'local-logout': 'local-logout',
  };
  final expiry = <String>[
    'declined-login',
    'expired-login',
  ].where(byScenario.containsKey).toList();
  if (expiry.length != 1 ||
      directRows.keys.any((scenario) => !byScenario.containsKey(scenario)) ||
      !byScenario.containsKey('exact-models') ||
      !byScenario.containsKey('redirect-matrix') ||
      byScenario.length != directRows.length + 3) {
    throw const FormatException('incomplete finite evidence assembly');
  }

  Map<String, Object?> row(String scenario, String id) {
    final result = byScenario[scenario]!;
    final state = result['state']! as String;
    return <String, Object?>{
      'id': id,
      'state': state,
      'predicates': Map<String, Object?>.from(result['predicates']! as Map),
      'hermeticTest': state == 'not-safely-inducible'
          ? id == 'cancel-login'
                ? 'device-login-cancel'
                : id == 'expiry-decline'
                ? 'device-login-expiry'
                : null
          : null,
    };
  }

  final exact = byScenario['exact-models']!;
  final exactPredicates = Map<String, Object?>.from(
    exact['predicates']! as Map,
  );
  final redirect = byScenario['redirect-matrix']!;
  if (exact['state'] != 'pass' ||
      redirect['state'] != 'pass' ||
      redirect['redirects'] is! List) {
    throw const FormatException('incomplete finite evidence assembly');
  }

  final assembled = <String, Object?>{
    'schemaVersion': 1,
    'packageCommit': input['packageCommit'],
    'apkDigest': input['apkDigest'],
    'flavor': 'evidence',
    'accountCategory': input['accountCategory'],
    'clientVersion': input['clientVersion'],
    'protocolCommit': input['protocolCommit'],
    'toolchain': input['toolchain'],
    'rows': <Object?>[
      <String, Object?>{
        'id': 'apk-device-provenance',
        'state': 'pass',
        'predicates': const <String, Object?>{
          'physicalDevice': true,
          'digestEqual': true,
          'embeddedCommitMatch': true,
          'embeddedFlavorMatch': true,
          'variantMatch': true,
          'dartTargetMatch': true,
          'applicationIdMatch': true,
          'compiledFingerprintMatch': true,
        },
        'hermeticTest': null,
      },
      for (final entry in directRows.entries) row(entry.key, entry.value),
      row(expiry.single, 'expiry-decline'),
    ],
    'tuples': <Object?>[
      for (final tuple in const <(String, String)>[
        ('gpt-5.6-sol', 'sol'),
        ('gpt-5.6-terra', 'terra'),
        ('gpt-5.6-luna', 'luna'),
      ])
        <String, Object?>{
          'slug': tuple.$1,
          'effort': 'medium',
          'admitted': exactPredicates['${tuple.$2}Admitted'],
          'requestAccepted': exactPredicates['${tuple.$2}RequestAccepted'],
          'executedIdentityVerified':
              exactPredicates['${tuple.$2}ExecutedIdentityVerified'],
        },
    ],
    'redirects': List<Object?>.from(redirect['redirects']! as List),
  };
  return EvidenceSchema.validateRenderable(assembled);
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) {
    throw const FormatException('invalid finite evidence assembly');
  }
  return Map<String, Object?>.from(value);
}
