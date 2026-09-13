import 'dart:convert';
import 'dart:io';

const _evidenceFingerprint = 'codex-auth-evidence-entrypoint-v1';
const _ordinaryForbidden = <String>[
  _evidenceFingerprint,
  'evidence-command.json',
  'evidence-result.json',
  'codex_auth/evidence_state_v1',
  'interrupt-after-refresh-risk',
  'invalid-grant',
];

/// Verifies flavor separation against compiled APK contents, not imports.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'usage: check_release_artifact.dart <ordinary-release.apk> <evidence-debug.apk>',
    );
  }
  final ordinary = await _unpacked(arguments[0]);
  final evidence = await _unpacked(arguments[1]);
  if (!evidence.contains(_evidenceFingerprint)) {
    throw StateError('evidence APK lacks the expected entrypoint fingerprint');
  }
  if (_ordinaryForbidden.any(ordinary.contains)) {
    throw StateError('ordinary APK contains evidence-only content');
  }
}

Future<String> _unpacked(String apk) async {
  final file = File(apk);
  if (!await file.exists()) throw StateError('APK missing');
  final result = await Process.run('unzip', <String>[
    '-p',
    file.path,
  ], stdoutEncoding: null);
  if (result.exitCode != 0) throw StateError('APK cannot be inspected');
  final bytes = result.stdout as List<int>;
  return latin1.decode(bytes, allowInvalid: true);
}
