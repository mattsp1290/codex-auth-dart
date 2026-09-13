import 'package:ayn_thor_evidence/credential_state_store.dart';
import 'package:codex_auth/codex_auth.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Driver implements DurableRecordDriver {
  String? value;
  var clears = 0;
  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }

  @override
  Future<void> commit(String envelope) async => value = envelope;
  @override
  Future<String?> read() async => value;
}

void main() {
  test(
    'refresh-risk recovery clears state before a fresh graph may use it',
    () async {
      final driver = _Driver();
      final original = CredentialStateStore(driver: driver);
      await original.transaction((transaction) async {
        await transaction.replace('synthetic-record');
        await transaction.markRefreshRisk('generation-0123456789');
      });
      final reconstructed = CredentialStateStore(driver: driver);
      await reconstructed.transaction((transaction) async {
        expect(transaction.requiresReauthentication, isTrue);
        expect(await transaction.read(), isNull);
      });
      expect(driver.value, isNull);
    },
  );

  test('a durable idle envelope survives a reconstructed store', () async {
    final driver = _Driver();
    final original = CredentialStateStore(driver: driver);
    await original.transaction((transaction) => transaction.replace('record'));
    final reconstructed = CredentialStateStore(driver: driver);
    expect(await reconstructed.recover(), AuthStatus.signedIn);
    await reconstructed.transaction((transaction) async {
      expect(transaction.requiresReauthentication, isFalse);
      expect(await transaction.read(), 'record');
    });
  });

  test('malformed durable state fails closed', () async {
    final driver = _Driver()..value = 'not json';
    final store = CredentialStateStore(driver: driver);
    expect(await store.recover(), AuthStatus.reauthenticationRequired);
    expect(driver.value, isNull);
    expect(driver.clears, 1);
  });
}
