import 'dart:convert';
import 'dart:io';

/// Emits immutable, non-secret protocol provenance and optionally verifies the
/// pinned Codex source contract before live use.
void main(List<String> arguments) {
  const commitPattern = r'^[0-9a-f]{40}$';
  if ((arguments.length != 2 && arguments.length != 3) ||
      !RegExp(commitPattern).hasMatch(arguments[0]) ||
      !RegExp(commitPattern).hasMatch(arguments[1])) {
    throw ArgumentError(
      'expected two full immutable commit hashes and optional source root',
    );
  }
  var verified = false;
  if (arguments.length == 3) {
    final root = Directory(arguments[2]);
    final revision = Process.runSync('git', <String>[
      '-C',
      root.path,
      'rev-parse',
      'HEAD',
    ]);
    if (revision.exitCode != 0 ||
        (revision.stdout as String).trim() != arguments[1]) {
      throw StateError(
        'source revision does not match the immutable Codex reference',
      );
    }
    final device = File('${root.path}/codex-rs/login/src/device_code_auth.rs');
    final auth = File('${root.path}/codex-rs/login/src/auth/manager.rs');
    final models = File(
      '${root.path}/codex-rs/codex-api/src/endpoint/models.rs',
    );
    final responses = File(
      '${root.path}/codex-rs/codex-api/src/endpoint/responses.rs',
    );
    if (!device.existsSync() ||
        !auth.existsSync() ||
        !models.existsSync() ||
        !responses.existsSync()) {
      throw StateError('pinned protocol source layout is unavailable');
    }
    final deviceText = device.readAsStringSync();
    final authText = auth.readAsStringSync();
    final modelsText = models.readAsStringSync();
    final responsesText = responses.readAsStringSync();
    final required = <bool>[
      deviceText.contains('/deviceauth/usercode'),
      deviceText.contains('device_auth_id'),
      deviceText.contains('code_verifier'),
      authText.contains('app_EMoamEEZ73f0CkXaXp7hrann'),
      modelsText.contains('client_version'),
      responsesText.contains('"/responses"'),
    ];
    if (required.any((value) => !value)) {
      throw StateError(
        'pinned protocol source differs from the expected contract',
      );
    }
    verified = true;
  }
  print(
    jsonEncode(<String, Object>{
      'goReferenceCommit': arguments[0],
      'codexSourceCommit': arguments[1],
      'catalogClientVersion': '0.154.0',
      'protocolVerified': verified,
    }),
  );
}
