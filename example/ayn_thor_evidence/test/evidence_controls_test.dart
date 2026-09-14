import 'dart:convert';

import 'package:ayn_thor_evidence/evidence_controls.dart';
import 'package:ayn_thor_evidence/evidence_state_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _command(Map<String, Object?> extra) => jsonEncode(<String, Object?>{
  'schemaVersion': 1,
  'scenario': 'exact-models',
  'packageCommit': 'a' * 40,
  'flavor': 'evidence',
  'nonce': 'b' * 64,
  ...extra,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts an allowlisted finite command', () {
    final command = EvidenceCommand.decode(_command(<String, Object?>{}));
    expect(command.scenario, EvidenceScenario.exactModels);
  });

  test('rejects unknown keys and arbitrary scenarios', () {
    expect(
      () => EvidenceCommand.decode(_command(<String, Object?>{'extra': true})),
      throwsFormatException,
    );
    expect(
      () => EvidenceCommand.decode(
        _command(<String, Object?>{'scenario': 'shell-command'}),
      ),
      throwsFormatException,
    );
  });

  test('result is finite and retains only bounded predicates', () {
    final command = EvidenceCommand.decode(_command(<String, Object?>{}));
    final result = EvidenceResult(
      command: command,
      state: EvidenceResultState.blocked,
      recovery: EvidenceRecovery.signedOut,
      protectedIo: 0,
      predicates: const <String, Object?>{'clearAcknowledged': true},
    );
    final value = jsonDecode(result.encode()) as Map<String, Object?>;
    expect(value['nonce'], command.nonce);
    expect(value['predicates'], <String, Object?>{'clearAcknowledged': true});
    expect(value.containsKey('message'), isFalse);
  });

  test('checkpoint round trip retains only command and closed state', () {
    final command = EvidenceCommand.decode(
      _command(<String, Object?>{
        'scenario': 'interrupt-after-replacement-commit',
      }),
    );
    final checkpoint = EvidenceCheckpoint(
      command: command,
      phase: EvidenceCheckpointPhase.afterReplacement,
      refreshResponseCount: 1,
      replacementAcknowledged: true,
      replacementGenerationVerified: true,
    );

    final decoded = EvidenceCheckpoint.decode(checkpoint.encode());
    expect(decoded.command.nonce, command.nonce);
    expect(decoded.phase, EvidenceCheckpointPhase.afterReplacement);
    expect(decoded.replacementGenerationVerified, isTrue);
    expect(checkpoint.encode(), isNot(contains('access')));
  });

  test('restored checkpoint rejects mismatched build provenance', () async {
    const channel = MethodChannel('codex_auth/evidence_state_v1');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readCheckpoint') {
            return EvidenceCheckpoint(
              command: EvidenceCommand.decode(_command(<String, Object?>{})),
              phase: EvidenceCheckpointPhase.refreshRisk,
              refreshResponseCount: 0,
              replacementAcknowledged: false,
              replacementGenerationVerified: false,
            ).encode();
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await expectLater(
      const EvidenceStateStore(
        channel: channel,
        expectedPackageCommit: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        expectedFlavor: 'evidence',
      ).readCheckpoint(),
      throwsFormatException,
    );
  });
}
