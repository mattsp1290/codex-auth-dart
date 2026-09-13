import 'dart:io';

import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

void main() {
  test('the real IO adapter does not contact redirect targets for every redirect status', () async {
    var sourceHits = 0;
    var targetHits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      if (request.uri.path == '/target') {
        targetHits++;
        await request.drain<void>();
        await request.response.close();
        return;
      }
      sourceHits++;
      await request.drain<void>();
      request.response.statusCode = int.parse(request.uri.pathSegments.single);
      request.response.headers.set(HttpHeaders.locationHeader, '/target');
      await request.response.close();
    });
    final transport = DartIoHttpTransport();
    addTearDown(() => transport.close(force: true));

    for (final status in <int>[301, 302, 303, 307, 308]) {
      final response = await transport.send(
        HttpRequestData(
          method: 'POST',
          uri: Uri.parse(
            'http://${server.address.address}:${server.port}/$status',
          ),
          headers: const <String, String>{'authorization': 'Bearer synthetic'},
          body: const <int>[1],
        ),
      );
      expect(response.statusCode, status);
      await response.body.drain<void>();
    }
    expect(sourceHits, 5);
    expect(targetHits, 0);
  });
}
