import 'package:ayn_thor_evidence/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ordinary host has no device code in its initial widget tree', (
    tester,
  ) async {
    await tester.pumpWidget(const EvidenceHostApp());
    expect(find.text('Codex authentication evidence'), findsOneWidget);
    expect(find.textContaining('ABCD-'), findsNothing);
  });
}
