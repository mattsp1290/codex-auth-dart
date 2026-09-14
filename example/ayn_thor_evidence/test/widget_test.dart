import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';
import 'package:ayn_thor_evidence/main.dart';
import 'package:ayn_thor_evidence/evidence_controller.dart';
import 'package:flutter/widgets.dart';
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

  testWidgets('code display immediately shows an active poll loop', (
    tester,
  ) async {
    await tester.pumpWidget(
      EvidenceHostApp(
        autoStartDeviceLogin: true,
        clientFactory: () => CodexAuthClient(
          CodexAuthOptions(
            store: _Store(),
            transport: _StartTransport(),
            delay: (_, signal) async {
              await signal!.whenCancelled;
              throwIfCancelled(signal);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Poll loop: active'), findsOneWidget);
    expect(find.textContaining('ABCD-1234'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('completion callback runs after signed-in frame is rendered', (
    tester,
  ) async {
    var callbackSawSignedInFrame = false;
    await tester.pumpWidget(
      EvidenceHostApp(
        autoStartDeviceLogin: true,
        clientFactory: () => CodexAuthClient(
          CodexAuthOptions(
            store: _Store(),
            transport: _ApprovedTransport(),
            delay: (_, _) async {},
          ),
        ),
        onDeviceLoginFinished: (_, _) async {
          callbackSawSignedInFrame = find
              .text('State: passed (AuthStatus.signedIn)')
              .evaluate()
              .isNotEmpty;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(callbackSawSignedInFrame, isTrue);
  });
}

final class _StartTransport implements HttpTransport {
  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async => HttpResponseData(
    200,
    const <String, String>{},
    Stream<List<int>>.value(
      utf8.encode(
        '{"device_auth_id":"synthetic-device",'
        '"user_code":"ABCD-1234","interval":1}',
      ),
    ),
  );
}

final class _Store implements CredentialStore {
  String? value;

  @override
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  }) => action(_Transaction(this));
}

final class _Transaction implements CredentialTransaction {
  const _Transaction(this.store);
  final _Store store;
  @override
  bool get requiresReauthentication => false;
  @override
  Future<void> clear() async => store.value = null;
  @override
  Future<void> clearAfterRefresh(String generation) async {}
  @override
  Future<void> markRefreshRisk(String generation) async {}
  @override
  Future<String?> read() async => store.value;
  @override
  Future<void> replace(String record) async => store.value = record;
  @override
  Future<void> replaceAfterRefresh(String generation, String record) async {}
  @override
  Future<void> restoreAfterNotDispatched(String generation) async {}
}

final class _ApprovedTransport implements HttpTransport {
  var calls = 0;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    calls++;
    final body = switch (calls) {
      1 => <String, Object?>{
        'device_auth_id': 'synthetic-device',
        'user_code': 'ABCD-1234',
        'interval': 1,
      },
      2 => <String, Object?>{
        'authorization_code': 'synthetic-code',
        'code_challenge': 'synthetic-challenge',
        'code_verifier': 'synthetic-verifier',
      },
      3 => <String, Object?>{
        'access_token': 'synthetic-access',
        'refresh_token': 'synthetic-refresh',
        'expires_in': 3600,
        'id_token': 'e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudCJ9fQ.sig',
      },
      _ => throw StateError('unexpected request'),
    };
    return HttpResponseData(
      200,
      const <String, String>{},
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    );
  }
}
