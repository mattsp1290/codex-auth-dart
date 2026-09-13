import 'dart:convert';

import 'package:codex_auth/codex_auth.dart';

/// Runs synthetic redirect probes through the real Android IO transport.
/// The loopback port is exposed only by the host runner through `adb reverse`.
final class RedirectEvidence {
  static const _statuses = <int>[301, 302, 303, 307, 308];

  Future<bool> run() async {
    final transport = DartIoHttpTransport();
    try {
      for (final requestClass in _RequestClass.values) {
        for (final status in _statuses) {
          final response = await transport.send(
            HttpRequestData(
              method: requestClass.method,
              uri: Uri.parse(
                'http://127.0.0.1:8787/source/${requestClass.id}/$status',
              ),
              headers: requestClass.headers,
              body: requestClass.body,
            ),
          );
          if (response.statusCode != status) return false;
          await response.body.drain<void>();
        }
      }
      return true;
    } on Object {
      return false;
    } finally {
      transport.close(force: true);
    }
  }
}

enum _RequestClass {
  deviceJson('device-json', 'POST', <String, String>{
    'content-type': 'application/json',
  }, '{"device_auth_id":"synthetic","user_code":"synthetic"}'),
  authorizationCodeForm('authorization-code-form', 'POST', <String, String>{
    'content-type': 'application/x-www-form-urlencoded',
  }, 'code=synthetic'),
  refreshTokenForm('refresh-token-form', 'POST', <String, String>{
    'content-type': 'application/x-www-form-urlencoded',
  }, 'refresh_token=synthetic'),
  catalogBearer('catalog-bearer', 'GET', <String, String>{
    'authorization': 'Bearer synthetic',
  }, null),
  responsesBearer('responses-bearer', 'POST', <String, String>{
    'authorization': 'Bearer synthetic',
    'content-type': 'application/json',
  }, '{}');

  const _RequestClass(this.id, this.method, this.headers, this.source);
  final String id;
  final String method;
  final Map<String, String> headers;
  final String? source;
  List<int> get body => source == null ? const <int>[] : utf8.encode(source!);
}
