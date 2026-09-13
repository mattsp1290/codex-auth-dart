import 'dart:async';
import 'dart:io';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real IO transport bounds stalled response headers as possibly dispatched',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        if (!received.isCompleted) received.complete();
        await request.drain<void>();
        await release.future;
        await request.response.close();
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      });
      final transport = DartIoHttpTransport(
        connectTimeout: const Duration(seconds: 1),
        responseHeaderTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(() => transport.close(force: true));

      await expectLater(
        transport.send(
          HttpRequestData(
            method: 'POST',
            uri: Uri.parse(
              'http://${server.address.address}:${server.port}/stall',
            ),
            body: const <int>[1],
          ),
        ),
        throwsA(
          isA<HttpTransportException>()
              .having(
                (error) => error.phase,
                'phase',
                HttpDispatchPhase.possiblyDispatched,
              )
              .having(
                (error) => error.outcome,
                'outcome',
                HttpTransportOutcome.responseHeaderTimeout,
              ),
        ),
      );
      await received.future.timeout(const Duration(seconds: 1));
    },
  );
}
