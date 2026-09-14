import 'package:ayn_thor_evidence/main.dart';
import 'package:ayn_thor_evidence/evidence_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ordinary host has no device code in its initial widget tree', (
    tester,
  ) async {
    await tester.pumpWidget(const EvidenceHostApp());
    expect(find.text('Codex authentication evidence'), findsOneWidget);
    expect(find.textContaining('ABCD-'), findsNothing);
  });

  test('resume preserves an active device-approval poll', () {
    expect(
      shouldRebuildGraphOnResume(true, EvidenceState.waitingForApproval),
      isFalse,
    );
    expect(shouldRebuildGraphOnResume(true, EvidenceState.idle), isTrue);
    expect(shouldRebuildGraphOnResume(false, EvidenceState.idle), isFalse);
  });
}
