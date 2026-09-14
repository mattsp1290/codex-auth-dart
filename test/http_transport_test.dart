import 'dart:async';
import 'dart:io';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

void main() {
  test('pre-cancelled IO requests never create a client', () async {
    final cancellation = CancellationController()..cancel();
    var factoryCalled = false;
    final transport = DartIoHttpTransport(
      clientFactory: () {
        factoryCalled = true;
        return HttpClient();
      },
    );

    await expectLater(
      transport.send(
        HttpRequestData(method: 'GET', uri: Uri.parse('http://127.0.0.1/')),
        cancellation: cancellation,
      ),
      throwsA(
        isA<HttpTransportException>()
            .having(
              (error) => error.phase,
              'phase',
              HttpDispatchPhase.notDispatched,
            )
            .having(
              (error) => error.outcome,
              'outcome',
              HttpTransportOutcome.cancelled,
            ),
      ),
    );
    expect(factoryCalled, isFalse);
  });

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

  test('real IO transport bounds an idle response body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.binary;
      request.response.write(<int>[1]);
      await request.response.flush();
      await release.future;
      await request.response.close();
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    });
    final transport = DartIoHttpTransport(
      streamIdleTimeout: const Duration(milliseconds: 40),
      overallTimeout: const Duration(seconds: 1),
    );
    addTearDown(() => transport.close(force: true));

    final response = await transport.send(
      HttpRequestData(
        method: 'GET',
        uri: Uri.parse('http://${server.address.address}:${server.port}/idle'),
      ),
    );
    await expectLater(
      response.body.drain<void>(),
      throwsA(
        isA<HttpTransportException>().having(
          (error) => error.outcome,
          'outcome',
          HttpTransportOutcome.streamIdleTimeout,
        ),
      ),
    );
    await response.close?.call();
    await response.close?.call();
  });

  test('real IO transport bounds a non-idle response overall', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      while (!release.isCompleted) {
        request.response.write(<int>[1]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await request.response.close();
    });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    });
    final transport = DartIoHttpTransport(
      streamIdleTimeout: const Duration(seconds: 1),
      overallTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(() => transport.close(force: true));

    final response = await transport.send(
      HttpRequestData(
        method: 'GET',
        uri: Uri.parse(
          'http://${server.address.address}:${server.port}/overall',
        ),
      ),
    );
    await expectLater(
      response.body.drain<void>(),
      throwsA(
        isA<HttpTransportException>().having(
          (error) => error.outcome,
          'outcome',
          HttpTransportOutcome.overallTimeout,
        ),
      ),
    );
  });
}
