import 'dart:io';

import 'package:test/test.dart';

import '../tool/evidence_schema.dart';

const _proofs = <String, List<(String, String)>>{
  'apk-device-provenance': [
    ('test/run_ayn_thor_matrix_test.dart', 'installedDigestMatches'),
  ],
  'approved-login': [
    ('test/device_login_test.dart', 'pending poll then approval'),
  ],
  'cancel-login': [('test/device_login_test.dart', 'cancel during poll delay')],
  'expiry-decline': [
    ('test/device_login_test.dart', 'deadline expiry dispatches no late poll'),
    ('test/device_login_test.dart', 'explicit decline maps'),
  ],
  'rehydrate-after-resume': [
    ('test/run_ayn_thor_matrix_test.dart', 'resume rehydration preserves'),
  ],
  'rehydrate-after-process-death': [
    ('test/run_ayn_thor_matrix_test.dart', 'process-death rehydration'),
  ],
  'two-client-rotation': [('test/refresh_test.dart', 'two clients serialize')],
  'interrupt-after-refresh-risk': [
    (
      'example/ayn_thor_evidence/test/evidence_scenario_support_test.dart',
      'pause checkpoints stay',
    ),
  ],
  'interrupt-before-replacement-commit': [
    (
      'example/ayn_thor_evidence/test/evidence_scenario_support_test.dart',
      'pause checkpoints stay',
    ),
  ],
  'interrupt-after-replacement-commit': [
    (
      'example/ayn_thor_evidence/test/evidence_scenario_support_test.dart',
      'pause checkpoints stay',
    ),
  ],
  'invalid-grant': [
    ('test/refresh_test.dart', 'invalid grant clears credentials'),
  ],
  'expired-without-refresh': [
    (
      'example/ayn_thor_evidence/test/evidence_scenario_support_test.dart',
      'expired and malformed seeds',
    ),
  ],
  'malformed-store': [
    (
      'example/ayn_thor_evidence/test/evidence_scenario_support_test.dart',
      'expired and malformed seeds',
    ),
  ],
  'catalog-and-unavailable': [
    ('test/model_catalog_test.dart', 'admits only exact visible API tuples'),
  ],
  'local-logout': [
    (
      'test/credential_store_test.dart',
      'local logout clears without transport I/O',
    ),
  ],
};

void main() {
  test('every renderable live row names an existing hermetic proof', () {
    expect(_proofs.keys.toSet(), EvidenceSchema.rowIds);
    for (final proofs in _proofs.values) {
      expect(proofs, isNotEmpty);
      for (final proof in proofs) {
        final file = File(proof.$1);
        expect(file.existsSync(), isTrue, reason: proof.$1);
        expect(file.readAsStringSync(), contains(proof.$2), reason: proof.$1);
      }
    }
  });
}
