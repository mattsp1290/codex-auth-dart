import 'dart:async';

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
    'cancelled waiter exits promptly without overtaking the holder',
    () async {
      final store = CredentialStateStore(driver: _Driver());
      final holderEntered = Completer<void>();
      final releaseHolder = Completer<void>();
      final holder = store.transaction((_) async {
        holderEntered.complete();
        await releaseHolder.future;
      });
      await holderEntered.future;

      final cancellation = CancellationController();
      var cancelledActionEntered = false;
      final waiter = store.transaction((_) async {
        cancelledActionEntered = true;
      }, cancellation: cancellation);
      cancellation.cancel();
      await expectLater(
        waiter.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<OperationCancelled>()),
      );
      expect(cancelledActionEntered, isFalse);

      var followerEntered = false;
      final follower = store.transaction((_) async {
        followerEntered = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(followerEntered, isFalse);
      releaseHolder.complete();
      await Future.wait(<Future<void>>[holder, follower]);
      expect(followerEntered, isTrue);
    },
  );

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

  test('refresh resolution is conditional on the marked generation', () async {
    final driver = _Driver();
    final store = CredentialStateStore(driver: driver);
    await store.transaction((transaction) async {
      await transaction.replace('synthetic-record');
      await transaction.markRefreshRisk('generation-0123456789');
      await expectLater(
        transaction.replaceAfterRefresh('different-generation', 'replacement'),
        throwsA(isA<CredentialStoreException>()),
      );
      await expectLater(
        transaction.clearAfterRefresh('different-generation'),
        throwsA(isA<CredentialStoreException>()),
      );
      await transaction.restoreAfterNotDispatched('generation-0123456789');
      expect(await transaction.read(), 'synthetic-record');
    });
  });
}
