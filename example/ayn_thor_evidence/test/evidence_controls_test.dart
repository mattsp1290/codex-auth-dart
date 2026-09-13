import 'dart:convert';

import 'package:ayn_thor_evidence/evidence_controls.dart';
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

  test('result is finite and retains only command correlation', () {
    final command = EvidenceCommand.decode(_command(<String, Object?>{}));
    final result = EvidenceResult(
      command: command,
      state: EvidenceResultState.blocked,
      recovery: EvidenceRecovery.signedOut,
      protectedIo: 0,
    );
    final value = jsonDecode(result.encode()) as Map<String, Object?>;
    expect(value['nonce'], command.nonce);
    expect(value.containsKey('message'), isFalse);
  });
}
