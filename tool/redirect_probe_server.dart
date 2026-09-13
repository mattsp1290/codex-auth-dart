import 'dart:convert';
import 'dart:io';

/// Synthetic-only redirect fixture. It stores field-presence booleans and
/// counts, never headers or body values.
Future<void> main(List<String> arguments) async {
  final port = arguments.isEmpty ? 8787 : int.parse(arguments.single);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final cases = <String, _CaseStats>{};
  final target = _CaseStats();

  await for (final request in server) {
    final path = request.uri.pathSegments;
    if (path.length == 1 &&
        path.single == 'reset' &&
        request.method == 'POST') {
      await request.drain<void>();
      cases.clear();
      target.reset();
      await request.response.close();
      continue;
    }
    if (path.length == 1 && path.single == 'status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'cases': cases.map((id, stats) => MapEntry(id, stats.json)),
          'target': target.json,
        }),
      );
      await request.response.close();
      continue;
    }
    if (path.length == 1 && path.single == 'target') {
      await target.record(request);
      await request.response.close();
      continue;
    }
    // /source/<finite-case-id>/<3xx-status>
    if (path.length == 3 && path.first == 'source') {
      final caseId = path[1];
      final status = int.tryParse(path[2]);
      if (!RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(caseId) ||
          status == null ||
          !<int>{301, 302, 303, 307, 308}.contains(status)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      await cases.putIfAbsent(caseId, _CaseStats.new).record(request);
      request.response.statusCode = status;
      request.response.headers.set(HttpHeaders.locationHeader, '/target');
      await request.response.close();
      continue;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

final class _CaseStats {
  int hits = 0;
  var authorization = false;
  var deviceAuthId = false;
  var userCode = false;
  var authorizationCode = false;
  var refreshToken = false;

  Future<void> record(HttpRequest request) async {
    hits++;
    authorization =
        authorization || request.headers.value('authorization') != null;
    final body = await utf8.decoder.bind(request).join();
    // Only booleans survive this request. The fixture is synthetic-only.
    deviceAuthId = deviceAuthId || _containsField(body, 'device_auth_id');
    userCode = userCode || _containsField(body, 'user_code');
    authorizationCode = authorizationCode || _containsField(body, 'code');
    refreshToken = refreshToken || _containsField(body, 'refresh_token');
  }

  bool _containsField(String body, String name) =>
      body.contains('"$name"') || body.contains('$name=');

  Map<String, Object?> get json => <String, Object?>{
    'hits': hits,
    'shape': <String, bool>{
      'authorization': authorization,
      'deviceAuthId': deviceAuthId,
      'userCode': userCode,
      'authorizationCode': authorizationCode,
      'refreshToken': refreshToken,
    },
  };

  void reset() {
    hits = 0;
    authorization = false;
    deviceAuthId = false;
    userCode = false;
    authorizationCode = false;
    refreshToken = false;
  }
}
