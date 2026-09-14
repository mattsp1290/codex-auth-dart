import 'dart:convert';

enum RawEvidenceRejection {
  jsonEmpty('validation-json-empty'),
  jsonEncoding('validation-json-encoding'),
  jsonPrefix('validation-json-prefix'),
  jsonSuffix('validation-json-suffix'),
  jsonBoundary('validation-json-boundary'),
  jsonSyntax('validation-json-syntax'),
  shape('validation-shape'),
  keys('validation-keys'),
  schemaVersion('validation-version'),
  scenario('validation-scenario'),
  packageCommit('validation-commit'),
  flavor('validation-flavor'),
  nonce('validation-nonce'),
  state('validation-state'),
  recovery('validation-recovery'),
  protectedIo('validation-protected-io'),
  predicates('validation-predicates'),
  category('validation-category');

  const RawEvidenceRejection(this.label);
  final String label;
}

/// Closed validation for the nonce-free, repository-renderable evidence record.
final class EvidenceSchema {
  static const schemaVersion = 1;
  static const states = <String>{
    'pass',
    'fail',
    'blocked',
    'not-safely-inducible',
  };
  static const accountCategories = <String>{
    'ChatGPT Plus',
    'ChatGPT Pro',
    'ChatGPT Business',
  };
  static const tupleSlugs = <String>{
    'gpt-5.6-sol',
    'gpt-5.6-terra',
    'gpt-5.6-luna',
  };
  static const _errorCategories = <String>{
    'cancelled',
    'reauthenticationRequired',
    'localCleanupRequired',
    'deviceAuthorizationDeclined',
    'deviceAuthorizationExpired',
    'protocolFailure',
    'redirectRefused',
    'modelUnavailable',
    'effortUnavailable',
    'staleAdmission',
    'planNotIncluded',
    'quotaExceeded',
    'requestFailed',
  };
  static const rowIds = <String>{
    'apk-device-provenance',
    'approved-login',
    'cancel-login',
    'expiry-decline',
    'rehydrate-after-resume',
    'rehydrate-after-process-death',
    'two-client-rotation',
    'interrupt-after-refresh-risk',
    'interrupt-before-replacement-commit',
    'interrupt-after-replacement-commit',
    'invalid-grant',
    'expired-without-refresh',
    'malformed-store',
    'catalog-and-unavailable',
    'local-logout',
  };

  static Map<String, Object?> parseRenderable(String source) =>
      validateRenderable(_object(jsonDecode(source)));

  /// Validates a nonce-bearing app-private result before its nonce is removed.
  static Map<String, Object?> validateRawResult(
    String source, {
    required String scenario,
    required String packageCommit,
    required String nonce,
  }) {
    final rejection = diagnoseRawResult(
      source,
      scenario: scenario,
      packageCommit: packageCommit,
      nonce: nonce,
    );
    if (rejection != null) _fail();
    return _object(jsonDecode(source));
  }

  static RawEvidenceRejection? diagnoseRawResult(
    String source, {
    required String scenario,
    required String packageCommit,
    required String nonce,
  }) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return RawEvidenceRejection.jsonEmpty;
    if (trimmed.contains('\uFFFD')) return RawEvidenceRejection.jsonEncoding;
    if (!trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return RawEvidenceRejection.jsonPrefix;
    }
    if (trimmed.startsWith('{') && !trimmed.endsWith('}')) {
      return RawEvidenceRejection.jsonSuffix;
    }
    if (!trimmed.startsWith('{') && !trimmed.endsWith('}')) {
      return RawEvidenceRejection.jsonBoundary;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return RawEvidenceRejection.jsonSyntax;
    }
    if (decoded is! Map) return RawEvidenceRejection.shape;
    Map<String, Object?> value;
    try {
      value = Map<String, Object?>.from(decoded);
    } on Object {
      return RawEvidenceRejection.shape;
    }
    const required = <String>{
      'schemaVersion',
      'scenario',
      'packageCommit',
      'flavor',
      'nonce',
      'state',
      'recovery',
      'protectedIo',
      'predicates',
    };
    const allowed = <String>{...required, 'category'};
    if (!value.keys.toSet().containsAll(required) ||
        value.keys.any((key) => !allowed.contains(key))) {
      return RawEvidenceRejection.keys;
    }
    if (value['schemaVersion'] != schemaVersion) {
      return RawEvidenceRejection.schemaVersion;
    }
    if (value['scenario'] != scenario) return RawEvidenceRejection.scenario;
    if (value['packageCommit'] != packageCommit) {
      return RawEvidenceRejection.packageCommit;
    }
    if (value['flavor'] != 'evidence') return RawEvidenceRejection.flavor;
    if (value['nonce'] is! String ||
        !_constantTime(value['nonce']! as String, nonce)) {
      return RawEvidenceRejection.nonce;
    }
    if (value['state'] is! String || !states.contains(value['state'])) {
      return RawEvidenceRejection.state;
    }
    if (value['recovery'] is! String ||
        !RegExp(r'^[a-z-]{1,64}$').hasMatch(value['recovery']! as String)) {
      return RawEvidenceRejection.recovery;
    }
    if (value['protectedIo'] is! int || (value['protectedIo']! as int) < 0) {
      return RawEvidenceRejection.protectedIo;
    }
    if (!_rawPredicates(value['predicates'])) {
      return RawEvidenceRejection.predicates;
    }
    if (value['state'] == 'pass' &&
        !_rawPassPredicates(
          scenario,
          Map<String, Object?>.from(value['predicates']! as Map),
        )) {
      return RawEvidenceRejection.predicates;
    }
    if (value['category'] != null &&
        !_errorCategories.contains(value['category'])) {
      return RawEvidenceRejection.category;
    }
    return null;
  }

  static Map<String, Object?> validateRenderable(Map<String, Object?> value) {
    _exactKeys(value, <String>{
      'schemaVersion',
      'packageCommit',
      'apkDigest',
      'flavor',
      'accountCategory',
      'clientVersion',
      'protocolCommit',
      'toolchain',
      'rows',
      'tuples',
      'redirects',
    });
    _equals(value['schemaVersion'], schemaVersion);
    _sha(value['packageCommit']);
    _digest(value['apkDigest']);
    _equals(value['flavor'], 'evidence');
    _oneOf(value['accountCategory'], accountCategories);
    _finiteLabel(value['clientVersion']);
    _sha(value['protocolCommit']);
    _toolchain(_object(value['toolchain']));
    _rows(_list(value['rows']));
    _tuples(_list(value['tuples']));
    _redirects(_list(value['redirects']));
    return value;
  }

  static void _toolchain(Map<String, Object?> value) {
    _exactKeys(value, <String>{
      'host',
      'device',
      'flutter',
      'dart',
      'androidSdk',
      'jdk',
      'gradle',
      'codex',
    });
    for (final entry in value.entries) {
      if (entry.key == 'device') {
        _equals(entry.value, 'ayn-thor');
      } else {
        _finiteLabel(entry.value);
      }
    }
  }

  static bool _rawPredicates(Object? value) {
    if (value is! Map || value.length > 32) return false;
    return value.entries.every(
      (entry) =>
          entry.key is String &&
          RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$')
              .hasMatch(entry.key as String) &&
          (entry.value is bool || entry.value is int),
    );
  }

  static bool _rawPassPredicates(
    String scenario,
    Map<String, Object?> predicates,
  ) {
    final expected = rawPassValues[scenario];
    if (expected == null || predicates.keys.toSet().length != expected.length) {
      return false;
    }
    return expected.entries.every(
      (entry) => predicates[entry.key] == entry.value,
    );
  }

  static const rawPassValues = <String, Map<String, Object>>{
    'approved-login': {
      'promptCleared': true,
      'approvalCompleted': true,
      'commitAcknowledged': true,
      'freshClient': true,
    },
    'cancel-login': {
      'promptCleared': true,
      'cancellationObserved': true,
      'credentialWriteCount': 0,
      'zeroProtectedIo': true,
    },
    'declined-login': {
      'promptCleared': true,
      'declinedOrExpired': true,
      'credentialWriteCount': 0,
      'zeroProtectedIo': true,
    },
    'expired-login': {
      'promptCleared': true,
      'declinedOrExpired': true,
      'credentialWriteCount': 0,
      'zeroProtectedIo': true,
    },
    'rehydrate-after-resume': {
      'graphChanged': true,
      'recoveryResolved': true,
      'noLoginRepeated': true,
      'resolvedBeforeProtectedIo': true,
      'freshClient': true,
    },
    'rehydrate-after-process-death': {
      'processChanged': true,
      'recoveryResolved': true,
      'noLoginRepeated': true,
      'resolvedBeforeProtectedIo': true,
      'freshClient': true,
    },
    'two-client-rotation': {
      'refreshCount': 1,
      'rotationObserved': true,
      'bothComplete': true,
      'noOverlapViolation': true,
      'freshClient': true,
    },
    'interrupt-after-refresh-risk': {
      'refreshRiskAcknowledged': true,
      'processChanged': true,
      'oldStateCleared': true,
      'zeroProtectedIoBeforeResolution': true,
      'reauthenticated': true,
      'freshClient': true,
    },
    'interrupt-before-replacement-commit': {
      'refreshResponseCount': 1,
      'refreshRiskAcknowledged': true,
      'replacementNotAcknowledged': true,
      'processChanged': true,
      'oldStateCleared': true,
      'zeroProtectedIoBeforeResolution': true,
      'reauthenticated': true,
      'freshClient': true,
    },
    'interrupt-after-replacement-commit': {
      'refreshResponseCount': 1,
      'replacementAcknowledged': true,
      'operationSuccessNotReported': true,
      'processChanged': true,
      'replacementGenerationVerified': true,
      'resolvedBeforeProtectedIo': true,
      'freshClient': true,
    },
    'invalid-grant': {
      'refreshCount': 1,
      'cleanupAcknowledged': true,
      'zeroProtectedIoBeforeReauthentication': true,
      'reauthenticated': true,
      'freshClient': true,
    },
    'expired-without-refresh': {
      'seedAcknowledged': true,
      'zeroProtectedIo': true,
      'cleanupAcknowledged': true,
      'reauthenticated': true,
      'freshClient': true,
    },
    'malformed-store': {
      'seedAcknowledged': true,
      'zeroProtectedIo': true,
      'cleanupAcknowledged': true,
      'reauthenticated': true,
      'freshClient': true,
    },
    'unavailable-tuple': {
      'catalogCount': 1,
      'allAdmitted': true,
      'unavailableRejected': true,
      'zeroResponses': true,
    },
    'exact-models': {
      'catalogCount': 1,
      'solAdmitted': true,
      'solRequestAccepted': true,
      'solExecutedIdentityVerified': true,
      'terraAdmitted': true,
      'terraRequestAccepted': true,
      'terraExecutedIdentityVerified': true,
      'lunaAdmitted': true,
      'lunaRequestAccepted': true,
      'lunaExecutedIdentityVerified': true,
    },
    'redirect-matrix': {'redirectCaseCount': 25},
    'local-logout': {
      'clearAcknowledged': true,
      'signedOut': true,
      'noRemoteRevocation': true,
    },
  };

  static void _rows(List<Object?> rows) {
    if (rows.length != rowIds.length) _fail();
    final seen = <String>{};
    for (final item in rows) {
      final row = _object(item);
      _exactKeys(row, <String>{'id', 'state', 'predicates', 'hermeticTest'});
      final id = _string(row['id']);
      if (!rowIds.contains(id) || !seen.add(id)) _fail();
      final state = _string(row['state']);
      _oneOf(state, states);
      final predicates = _object(row['predicates']);
      if (predicates.values.any((value) => value is! bool && value is! int)) {
        _fail();
      }
      final allowed = _passPredicates[id]!;
      if (predicates.keys.any((key) => !allowed.contains(key))) _fail();
      final substitute = row['hermeticTest'];
      if (state == 'not-safely-inducible') {
        const hermeticTests = <String, String>{
          'cancel-login': 'device-login-cancel',
          'expiry-decline': 'device-login-expiry',
        };
        final expected = hermeticTests[id];
        if (expected == null || substitute != expected) _fail();
      } else if (substitute != null) {
        _fail();
      }
      if (state == 'pass') _passRow(id, predicates);
    }
    if (seen.length != rowIds.length) _fail();
  }

  static const _passPredicates = <String, Set<String>>{
    'apk-device-provenance': {
      'physicalDevice',
      'digestEqual',
      'embeddedCommitMatch',
      'embeddedFlavorMatch',
      'variantMatch',
      'dartTargetMatch',
      'applicationIdMatch',
      'compiledFingerprintMatch',
    },
    'approved-login': {
      'approvalCompleted',
      'commitAcknowledged',
      'promptCleared',
      'freshClient',
    },
    'cancel-login': {
      'cancellationObserved',
      'credentialWriteCount',
      'promptCleared',
      'zeroProtectedIo',
    },
    'expiry-decline': {
      'declinedOrExpired',
      'credentialWriteCount',
      'promptCleared',
      'zeroProtectedIo',
    },
    'rehydrate-after-resume': {
      'graphChanged',
      'recoveryResolved',
      'noLoginRepeated',
      'resolvedBeforeProtectedIo',
      'freshClient',
    },
    'rehydrate-after-process-death': {
      'processChanged',
      'recoveryResolved',
      'noLoginRepeated',
      'resolvedBeforeProtectedIo',
      'freshClient',
    },
    'two-client-rotation': {
      'refreshCount',
      'rotationObserved',
      'bothComplete',
      'noOverlapViolation',
      'freshClient',
    },
    'interrupt-after-refresh-risk': {
      'refreshRiskAcknowledged',
      'processChanged',
      'oldStateCleared',
      'zeroProtectedIoBeforeResolution',
      'reauthenticated',
      'freshClient',
    },
    'interrupt-before-replacement-commit': {
      'refreshResponseCount',
      'refreshRiskAcknowledged',
      'replacementNotAcknowledged',
      'processChanged',
      'oldStateCleared',
      'zeroProtectedIoBeforeResolution',
      'reauthenticated',
      'freshClient',
    },
    'interrupt-after-replacement-commit': {
      'refreshResponseCount',
      'replacementAcknowledged',
      'operationSuccessNotReported',
      'processChanged',
      'replacementGenerationVerified',
      'resolvedBeforeProtectedIo',
      'freshClient',
    },
    'invalid-grant': {
      'refreshCount',
      'cleanupAcknowledged',
      'zeroProtectedIoBeforeReauthentication',
      'reauthenticated',
      'freshClient',
    },
    'expired-without-refresh': {
      'seedAcknowledged',
      'zeroProtectedIo',
      'cleanupAcknowledged',
      'reauthenticated',
      'freshClient',
    },
    'malformed-store': {
      'seedAcknowledged',
      'zeroProtectedIo',
      'cleanupAcknowledged',
      'reauthenticated',
      'freshClient',
    },
    'catalog-and-unavailable': {
      'catalogCount',
      'allAdmitted',
      'unavailableRejected',
      'zeroResponses',
    },
    'local-logout': {'clearAcknowledged', 'signedOut', 'noRemoteRevocation'},
  };

  static void _passRow(String id, Map<String, Object?> p) {
    final needed = _passPredicates[id]!;
    for (final key in needed) {
      final value = p[key];
      if (key.endsWith('Count')) {
        if (value is! int ||
            value < 0 ||
            (key == 'refreshCount' && value != 1) ||
            (key == 'refreshResponseCount' && value != 1) ||
            (key == 'credentialWriteCount' && value != 0) ||
            (key == 'catalogCount' && value != 1)) {
          _fail();
        }
      } else if (value != true) {
        _fail();
      }
    }
  }

  static void _tuples(List<Object?> tuples) {
    if (tuples.length != tupleSlugs.length) _fail();
    final seen = <String>{};
    for (final item in tuples) {
      final tuple = _object(item);
      _exactKeys(tuple, <String>{
        'slug',
        'effort',
        'admitted',
        'requestAccepted',
        'executedIdentityVerified',
      });
      final slug = _string(tuple['slug']);
      if (!tupleSlugs.contains(slug) || !seen.add(slug)) _fail();
      _equals(tuple['effort'], 'medium');
      if (tuple['admitted'] != true ||
          tuple['requestAccepted'] != true ||
          tuple['executedIdentityVerified'] != true) {
        _fail();
      }
    }
  }

  static void _redirects(List<Object?> redirects) {
    if (redirects.length != 25) _fail();
    final seen = <String>{};
    const classes = <String>{
      'device-json',
      'authorization-code-form',
      'refresh-token-form',
      'catalog-bearer',
      'responses-bearer',
    };
    const statuses = <int>{301, 302, 303, 307, 308};
    for (final item in redirects) {
      final row = _object(item);
      _exactKeys(row, <String>{
        'requestClass',
        'status',
        'sourceHits',
        'targetHits',
        'sourceShape',
        'targetShape',
        'peerClosed',
      });
      final kind = _string(row['requestClass']);
      final status = row['status'];
      if (!classes.contains(kind) ||
          status is! int ||
          !statuses.contains(status) ||
          !seen.add('$kind:$status')) {
        _fail();
      }
      if (row['sourceHits'] != 1 ||
          row['targetHits'] != 0 ||
          row['peerClosed'] != true) {
        _fail();
      }
      final sourceShape = _object(row['sourceShape']);
      final targetShape = _object(row['targetShape']);
      final expectedShape = _redirectSourceShapes[kind]!;
      if (sourceShape.keys.toSet().length != expectedShape.length ||
          expectedShape.entries.any(
            (entry) => sourceShape[entry.key] != entry.value,
          ) ||
          targetShape.keys.toSet().length != expectedShape.length ||
          targetShape.values.any((value) => value != false)) {
        _fail();
      }
    }
  }

  static const _redirectSourceShapes = <String, Map<String, bool>>{
    'device-json': {
      'authorization': false,
      'deviceAuthId': true,
      'userCode': true,
      'authorizationCode': false,
      'refreshToken': false,
    },
    'authorization-code-form': {
      'authorization': false,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': true,
      'refreshToken': false,
    },
    'refresh-token-form': {
      'authorization': false,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': true,
    },
    'catalog-bearer': {
      'authorization': true,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': false,
    },
    'responses-bearer': {
      'authorization': true,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': false,
    },
  };

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map) _fail();
    return Map<String, Object?>.from(value);
  }

  static List<Object?> _list(Object? value) => value is List ? value : _fail();
  static String _string(Object? value) => value is String ? value : _fail();
  static void _exactKeys(Map<String, Object?> value, Set<String> keys) {
    if (value.keys.toSet().length != keys.length ||
        !value.keys.toSet().containsAll(keys)) {
      _fail();
    }
  }

  static void _equals(Object? value, Object expected) {
    if (value != expected) _fail();
  }

  static void _oneOf(Object? value, Set<String> values) {
    if (value is! String || !values.contains(value)) _fail();
  }

  static void _sha(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) _fail();
  }

  static void _digest(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) _fail();
  }

  static void _finiteLabel(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9._ -]{1,96}$').hasMatch(value) ||
        value.contains('  ')) {
      _fail();
    }
  }

  static bool _constantTime(String first, String second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
    }
    return difference == 0;
  }

  static Never _fail() =>
      throw const FormatException('invalid finite evidence schema');
}
