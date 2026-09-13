import 'dart:convert';
import 'dart:io';

/// Synthetic-only redirect fixture for Android/IO-adapter containment evidence.
/// It records counts and credential-field presence, never values or bodies.
Future<void> main(List<String> arguments) async {
  final port = arguments.isEmpty ? 8787 : int.parse(arguments.single);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final sourceHits = <String, int>{};
  var targetHits = 0;
  var targetAuthorization = false;
  var targetFormCredential = false;

  await for (final request in server) {
    final path = request.uri.path;
    if (path == '/status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'sourceHits': sourceHits,
          'targetHits': targetHits,
          'targetAuthorization': targetAuthorization,
          'targetFormCredential': targetFormCredential,
        }),
      );
      await request.response.close();
      continue;
    }
    if (path == '/target') {
      targetHits++;
      targetAuthorization =
          targetAuthorization || request.headers.value('authorization') != null;
      final body = await utf8.decoder.bind(request).join();
      targetFormCredential =
          targetFormCredential ||
          body.contains('refresh_token=') ||
          body.contains('code=');
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      continue;
    }
    if (path.startsWith('/source/')) {
      final status =
          int.tryParse(path.substring('/source/'.length)) ?? HttpStatus.found;
      sourceHits[path] = (sourceHits[path] ?? 0) + 1;
      await request.drain<void>();
      request.response.statusCode = status;
      request.response.headers.set(HttpHeaders.locationHeader, '/target');
      await request.response.close();
      continue;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}
