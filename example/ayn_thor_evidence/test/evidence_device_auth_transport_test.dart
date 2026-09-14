import 'dart:async';
import 'dart:convert';

import 'package:ayn_thor_evidence/evidence_device_auth_transport.dart';
import 'package:codex_auth/codex_auth.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Transport implements HttpTransport {
  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async => HttpResponseData(
    403,
    const <String, String>{},
    Stream<List<int>>.value(utf8.encode('{}')),
  );
}

void main() {
  test('records only finite poll count and status', () async {
    final telemetry = DeviceAuthTelemetry();
    var changes = 0;
    final transport = EvidenceDeviceAuthTransport(
      _Transport(),
      telemetry: telemetry,
      onChanged: () => changes++,
    );

    await transport.send(
      HttpRequestData(
        method: 'POST',
        uri: Uri.https('auth.openai.com', '/api/accounts/deviceauth/token'),
      ),
    );
    await transport.send(
      HttpRequestData(
        method: 'POST',
        uri: Uri.https('auth.openai.com', '/api/accounts/deviceauth/usercode'),
      ),
    );

    expect(telemetry.attemptsStarted, 1);
    expect(telemetry.attemptsCompleted, 1);
    expect(telemetry.inFlight, isFalse);
    expect(telemetry.lastStatus, 403);
    expect(changes, 2);
  });

  test('announces a poll attempt before its response completes', () async {
    final response = Completer<HttpResponseData>();
    final telemetry = DeviceAuthTelemetry();
    var changes = 0;
    final transport = EvidenceDeviceAuthTransport(
      _PendingTransport(response),
      telemetry: telemetry,
      onChanged: () => changes++,
    );

    final pending = transport.send(
      HttpRequestData(
        method: 'POST',
        uri: Uri.https('auth.openai.com', '/api/accounts/deviceauth/token'),
      ),
    );
    expect(telemetry.attemptsStarted, 1);
    expect(telemetry.attemptsCompleted, 0);
    expect(telemetry.inFlight, isTrue);
    expect(changes, 1);

    response.complete(
      HttpResponseData(
        403,
        const <String, String>{},
        Stream<List<int>>.value(utf8.encode('{}')),
      ),
    );
    await pending;
    expect(telemetry.attemptsCompleted, 1);
    expect(telemetry.inFlight, isFalse);
    expect(changes, 2);
  });
}

final class _PendingTransport implements HttpTransport {
  const _PendingTransport(this.response);
  final Completer<HttpResponseData> response;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) => response.future;
}
