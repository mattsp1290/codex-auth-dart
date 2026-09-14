import 'dart:convert';

/// Closed evidence scenarios. No arbitrary scenario or parameter is accepted.
enum EvidenceScenario {
  approvedLogin('approved-login'),
  cancelLogin('cancel-login'),
  declinedLogin('declined-login'),
  expiredLogin('expired-login'),
  rehydrateAfterResume('rehydrate-after-resume'),
  rehydrateAfterProcessDeath('rehydrate-after-process-death'),
  twoClientRotation('two-client-rotation'),
  interruptAfterRefreshRisk('interrupt-after-refresh-risk'),
  interruptBeforeReplacementCommit('interrupt-before-replacement-commit'),
  interruptAfterReplacementCommit('interrupt-after-replacement-commit'),
  invalidGrant('invalid-grant'),
  expiredWithoutRefresh('expired-without-refresh'),
  malformedStore('malformed-store'),
  unavailableTuple('unavailable-tuple'),
  exactModels('exact-models'),
  redirectMatrix('redirect-matrix'),
  localLogout('local-logout');

  const EvidenceScenario(this.wireName);
  final String wireName;

  static EvidenceScenario parse(String value) {
    for (final scenario in EvidenceScenario.values) {
      if (scenario.wireName == value) return scenario;
    }
    throw const FormatException('unknown evidence scenario');
  }
}

/// One single-use host command. It contains no credentials or device identity.
final class EvidenceCommand {
  const EvidenceCommand({
    required this.scenario,
    required this.packageCommit,
    required this.flavor,
    required this.nonce,
  });
  final EvidenceScenario scenario;
  final String packageCommit;
  final String flavor;
  final String nonce;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'scenario': scenario.wireName,
    'packageCommit': packageCommit,
    'flavor': flavor,
    'nonce': nonce,
  };

  static EvidenceCommand decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, Object?> ||
        value.keys.toSet().length != 5 ||
        !value.keys.toSet().containsAll(<String>{
          'schemaVersion',
          'scenario',
          'packageCommit',
          'flavor',
          'nonce',
        }) ||
        value['schemaVersion'] != 1 ||
        value['scenario'] is! String ||
        value['packageCommit'] is! String ||
        value['flavor'] != 'evidence' ||
        value['nonce'] is! String ||
        !_isLowerHex(value['packageCommit']! as String, 40) ||
        !_isLowerHex(value['nonce']! as String, 64)) {
      throw const FormatException('invalid evidence command');
    }
    return EvidenceCommand(
      scenario: EvidenceScenario.parse(value['scenario']! as String),
      packageCommit: value['packageCommit']! as String,
      flavor: 'evidence',
      nonce: value['nonce']! as String,
    );
  }
}

enum EvidenceCheckpointPhase {
  rehydrationReady('rehydration-ready'),
  refreshRisk('refresh-risk'),
  beforeReplacement('before-replacement'),
  afterReplacement('after-replacement');

  const EvidenceCheckpointPhase(this.wireName);
  final String wireName;
}

final class EvidenceCheckpoint {
  const EvidenceCheckpoint({
    required this.command,
    required this.phase,
    required this.refreshResponseCount,
    required this.replacementAcknowledged,
    required this.replacementGenerationVerified,
  });

  final EvidenceCommand command;
  final EvidenceCheckpointPhase phase;
  final int refreshResponseCount;
  final bool replacementAcknowledged;
  final bool replacementGenerationVerified;

  String encode() => jsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'command': command.toJson(),
    'phase': phase.wireName,
    'refreshResponseCount': refreshResponseCount,
    'replacementAcknowledged': replacementAcknowledged,
    'replacementGenerationVerified': replacementGenerationVerified,
  });

  static EvidenceCheckpoint decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map ||
        value.keys.toSet().length != 6 ||
        !value.keys.toSet().containsAll(<String>{
          'schemaVersion',
          'command',
          'phase',
          'refreshResponseCount',
          'replacementAcknowledged',
          'replacementGenerationVerified',
        }) ||
        value['schemaVersion'] != 1 ||
        value['command'] is! Map ||
        value['refreshResponseCount'] is! int ||
        value['replacementAcknowledged'] is! bool ||
        value['replacementGenerationVerified'] is! bool) {
      throw const FormatException('invalid evidence checkpoint');
    }
    final phase = EvidenceCheckpointPhase.values.where(
      (candidate) => candidate.wireName == value['phase'],
    );
    if (phase.length != 1) {
      throw const FormatException('invalid evidence checkpoint');
    }
    return EvidenceCheckpoint(
      command: EvidenceCommand.decode(jsonEncode(value['command'])),
      phase: phase.single,
      refreshResponseCount: value['refreshResponseCount']! as int,
      replacementAcknowledged: value['replacementAcknowledged']! as bool,
      replacementGenerationVerified:
          value['replacementGenerationVerified']! as bool,
    );
  }
}

bool _isLowerHex(String value, int length) =>
    value.length == length &&
    value.codeUnits.every(
      (unit) => (unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102),
    );

enum EvidenceResultState { pass, fail, blocked, notSafelyInducible }

enum EvidenceRecovery {
  signedOut('signed-out'),
  signedIn('signed-in'),
  reauthenticationRequired('reauthentication-required'),
  cleanupRequired('cleanup-required');

  const EvidenceRecovery(this.wireName);
  final String wireName;
}

const _errorCategories = <String>{
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

/// Token-free finite result persisted separately from credential state.
final class EvidenceResult {
  const EvidenceResult({
    required this.command,
    required this.state,
    required this.recovery,
    required this.protectedIo,
    this.category,
    this.predicates = const <String, Object?>{},
  }) : assert(protectedIo >= 0);
  final EvidenceCommand command;
  final EvidenceResultState state;
  final EvidenceRecovery recovery;
  final int protectedIo;
  final String? category;
  final Map<String, Object?> predicates;

  String encode() {
    if (protectedIo < 0 ||
        (category != null && !_errorCategories.contains(category)) ||
        predicates.length > 32 ||
        predicates.entries.any(
          (entry) =>
              !RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(entry.key) ||
              (entry.value is! bool && entry.value is! int),
        )) {
      throw StateError('invalid finite evidence result');
    }
    return jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'scenario': command.scenario.wireName,
      'packageCommit': command.packageCommit,
      'flavor': command.flavor,
      'nonce': command.nonce,
      'state': state.name == 'notSafelyInducible'
          ? 'not-safely-inducible'
          : state.name,
      'recovery': recovery.wireName,
      'protectedIo': protectedIo,
      'predicates': predicates,
      if (category != null) 'category': category,
    });
  }
}
