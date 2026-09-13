import 'package:test/test.dart';

import '../tool/src/ayn_thor_matrix_adapter.dart';

void main() {
  test('result polling ignores non-empty transport diagnostics', () {
    expect(isFiniteResultCandidate('transport diagnostic'), isFalse);
    expect(isFiniteResultCandidate(''), isFalse);
    expect(isFiniteResultCandidate('  {"state":"pass"}\n'), isTrue);
  });
}
