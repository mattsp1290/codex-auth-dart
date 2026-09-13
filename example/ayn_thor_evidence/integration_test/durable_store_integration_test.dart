import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ayn_thor_evidence/credential_state_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native driver acknowledges durable reconstruction and clear', (
    tester,
  ) async {
    const first = MethodChannelDurableRecordDriver();
    const second = MethodChannelDurableRecordDriver();
    const envelope = '{"v":1,"state":"signedOut"}';

    await first.clear();
    await first.commit(envelope);
    expect(await second.read(), envelope);
    await second.clear();
    expect(await first.read(), isNull);
  });
}
